# SoulChange plugin.
# A simple queue for soul change skill.
#
# This plugin listens to "I need mana!" party message and queue the sender for soul change.
#
# available config:
#   soulChange [1|0] - enable or disable the plugin.
#   soulChange_minSPPercent [value] - minimum SP to cast the soul change, default to 50 (percent).
#   soulChange_timeout [value] - timeout for the soul change skill, default to 5 (seconds).
#   soulChange_priority [value] - priority for the queue, comma separated.
#   soulChange_maxAttempts [value] - maximum number of attempts allowed to use soul change, default to 2.
#   soulChange_emotion [id,id...] - optional, comma-separated list of emotion IDs that should trigger a soul change (if omitted any emotion will trigger)
#
# You can use this plugin with doCommand block in your config.txt. For example:
#  doCommand p I need mana! {
#    partyAggressives > 0
#    sp < 20%
#    timeout 5
#  }
#  doCommand e sptime {
#	sp < 19%
#	timeout 5
#	disabled 0
# }

package soulChange;

use strict;

use Plugins;
use Globals;
use Log qw(message);
use Time::HiRes qw(time);
use Utils;
use Misc;
use Commands;
use AI;
use Actor;

Plugins::register('soulChange', 'Simple queue for soul change',\&unload, \&unload);

my $hooks = Plugins::addHooks(
	['AI_pre', \&onAIPre, undef],
	['packet_partyMsg', \&onPartyMsg, undef],
	['packet_chat', \&onPartyMsg, undef],
	['packet_message', \&onPartyMsg, undef],
	['packet_publicMsg', \&onPartyMsg, undef],
	['packet_public', \&onPartyMsg, undef],
	['packet_party', \&onPartyMsg, undef],

	['packet_emotion', \&onEmotion, undef],
	['packet_emote', \&onEmotion, undef],
	['packet_emoticon', \&onEmotion, undef],
	['packet_emotionMsg', \&onEmotion, undef],
	['packet_emot', \&onEmotion, undef],
	['packet_emotion2', \&onEmotion, undef],
	['packet_emote2', \&onEmotion, undef],
	['packet_emoticon2', \&onEmotion, undef],
	['packet_emotionMsg2', \&onEmotion, undef],
	['packet_emoteMsg', \&onEmotion, undef],
	['packet_emoticon_msg', \&onEmotion, undef],
	['packet_actor_emotion', \&onEmotion, undef],
	['packet_actor_action', \&onEmotion, undef],
	['packet_action', \&onEmotion, undef],
	['packet_user_emotion', \&onEmotion, undef],
	['packet_skilluse', \&onSkillUse, undef],
);

my $attempts = 0;
my $defaultMaxAttempts = 2;
my %priorityHash = ();
my $prioQueue = [];

my $timer = time;

sub unload {
	Plugins::delHooks($hooks);
}

sub onAIPre {
	processSoulChange();
}

sub onPartyMsg {
	return unless $config{soulChange};
	my (undef, $args) = @_;

	my $msg = '';
	my $user = undef;
	if (ref $args eq 'HASH') {
		$msg  = $args->{Msg} || $args->{message} || $args->{text} || $args->{msg} || '';
		$user = $args->{MsgUser} || $args->{User} || $args->{name} || $args->{from};
	} else {
		$msg = $args;
	}

	$msg =~ s/^\s+|\s+$//g if defined $msg && $msg ne '';

	# Only handle the explicit party request
	if (defined $msg && $msg eq "I need mana!") {
		insert($user // $args->{MsgUser});
		return;
	}
}

sub onEmotion {
	return unless $config{soulChange};

	my (undef, $args) = @_;

	# Extract raw emotion value from various possible fields
	my $raw_emotion;
	if (!defined $args) {
		return;
	} elsif (ref $args eq 'HASH') {
		$raw_emotion = $args->{emotion} // $args->{emot} // $args->{type} // $args->{action} // $args->{emotionID} // $args->{emotid} // $args->{id};
	} elsif (ref $args eq 'ARRAY') {
		$raw_emotion = $args->[1] // $args->[2];
	} else {
		$raw_emotion = $args;
	}

	# Decide whether this emotion matches configured/default triggers
	my $matches_emotion = 0;
	if (defined $config{soulChange_emotion} && $config{soulChange_emotion} ne '') {
		my %emHash = map { $_ => 1 } split / *, */, $config{soulChange_emotion};
		$matches_emotion = 1 if defined $raw_emotion && $emHash{$raw_emotion};
	} else {
		if (defined $raw_emotion) {
			if ($raw_emotion =~ /^\d+$/ && $raw_emotion == 42) {
				$matches_emotion = 1;
			} elsif ($raw_emotion =~ /^\*?SP\*?\z/i || $raw_emotion =~ /sptime/i || $raw_emotion =~ /\be7\b/i || $raw_emotion =~ /\bmp\b/i) {
				$matches_emotion = 1;
			}
		}
	}

	return unless $matches_emotion;

	# Resolve the source/player ID which may be numeric, name, or raw binary ID
	my $source_raw;
	if (ref $args eq 'HASH') {
		$source_raw = $args->{sourceID} // $args->{ID} // $args->{source} // $args->{playerID} // $args->{player_id} // $args->{char_id} // $args->{ownerID};
	} elsif (ref $args eq 'ARRAY') {
		$source_raw = $args->[0];
	}

	my $sourceID;
	my $player;

	# 1) Try Actor::get (works with binary IDs)
	if (defined $source_raw && length($source_raw) > 0) {
		eval {
			my $actor = Actor::get($source_raw, 1);
			if ($actor && $actor->{actorType} && $actor->{actorType} eq 'Player') {
				$player = $actor;
				$sourceID = $actor->{nameID} if defined $actor->{nameID};
			}
		};
	}

	# 2) Numeric or unpacked ID
	if (!$player && defined $source_raw) {
		if ($source_raw =~ /^\d+$/) {
			$sourceID = $source_raw;
			$player = $playersList->getByID($sourceID);
		} else {
			my ($id_le, $id_be);
			eval {
				if (length($source_raw) >= 4) {
					my $bytes = substr($source_raw, 0, 4);
					$id_le = unpack('V', $bytes);
					$id_be = unpack('N', $bytes);
				} else {
					my @o = map { ord($_) } split //, $source_raw;
					$id_le = 0; for my $i (0 .. $#o) { $id_le += $o[$i] << ($i * 8); }
					$id_be = 0; for my $i (0 .. $#o) { $id_be = ($id_be << 8) + $o[$i]; }
				}
			};

			$player = $playersList->getByID($id_le) if defined $id_le;
			$player = $playersList->getByID($id_be) if !$player && defined $id_be;
			$sourceID = $id_le if !defined $sourceID && defined $id_le;

			# 3) Try matching raw binary to known players
			if (!$player) {
				eval {
					foreach my $pid (@::playersID) {
						my $pl = $::players{$pid};
						next unless $pl && defined $pl->{ID};
						my $pl_id = $pl->{ID};
						my $bin_le = pack('V', $pl_id);
						my $bin_be = pack('N', $pl_id);
						if ($source_raw eq $bin_le || $source_raw eq $bin_be || index($source_raw, $bin_le) >= 0 || index($source_raw, $bin_be) >= 0 || index($bin_le, $source_raw) >= 0 || index($bin_be, $source_raw) >= 0) {
							$player = $pl;
							$sourceID = $pl_id;
							last;
						}
					}
				};

				# 4) Exhaustive 4-byte window scan
				if (!$player) {
					my $sr_len = length($source_raw);
					for my $off (0 .. $sr_len - 4) {
						my $w = substr($source_raw, $off, 4);
						eval {
							my $cand_le = unpack('V', $w);
							my $cand_be = unpack('N', $w);
							if (defined $cand_le) {
								my $p = $playersList->getByID($cand_le);
								if ($p) { $player = $p; $sourceID = $cand_le; last; }
							}
							if (defined $cand_be) {
								my $p2 = $playersList->getByID($cand_be);
								if ($p2) { $player = $p2; $sourceID = $cand_be; last; }
							}
						};
						last if $player;
					}
				}
			}
		}
	}

	# 5) Try to resolve by sourceID
	if (!$player && defined $sourceID) {
		$player = $playersList->getByID($sourceID);
	}

	# 6) Name fields fallback
	if (!$player && ref $args eq 'HASH') {
		for my $k (qw(MsgUser User name player username targetName target player_name)) {
			if (defined $args->{$k}) { $player = Match::player($args->{$k}); last; }
		}
	}

	# 7) Raw text fallback
	if (!$player && ref $args eq 'HASH') {
		my $raw = $args->{raw} || $args->{Raw} || $args->{msg} || $args->{message} || $args->{text};
		if (defined $raw && $raw =~ /(?:\[dist=[^\]]*\] )?([^\(\n]+) \(\d+\):/) {
			my $name = $1; $name =~ s/^\s+|\s+$//g;
			$player = Match::player($name);
		}
	}

	# 8) Proximity fallback
	if (!$player) {
		my $best; my $bestd = 999999;
		foreach my $pid (@::playersID) {
			my $pl = $::players{$pid};
			next unless $pl && defined $pl->{name};
			next if $pl->{name} eq $char->{name};
			next if $pl->{dead};
			eval {
				my $d = distance(calcPosition($char), calcPosition($pl));
				if (defined $d && $d < $bestd) { $bestd = $d; $best = $pl; }
			};
		}
		my $maxdist = $config{soulChange_maxDistance} || 8;
		if ($best && $bestd <= $maxdist) { $player = $best; }
	}

	if ($player) {
		insert($player->{name});
		return;
	}

	# no last-console fallback (onConsole removed)
}

sub processSoulChange {
	return unless $config{soulChange};
	return unless scalar(@{$prioQueue}) > 0;
	return if $char->sp_percent() < ($config{soulChange_minSPPercent} || 50);

	my $timeout = $config{soulChange_timeout} || 5;
	my $maxAttempts = $config{soulChange_maxAttempts} || $defaultMaxAttempts;

	if (AI::isIdle || AI::is(qw(route mapRoute follow sitAuto take items_gather items_take attack move))) {
		my $target = $prioQueue->[0]{name};

		if ($attempts >= $maxAttempts) {
			remove($target);
			$attempts = 0;
			return;
		}

		my $player = Match::player($target);
		if ($player && timeOut($timer, $timeout)) {
			$timer = time;

			if ($player->{dead}) {
				remove($target);
				$attempts = 0;
				return;
			}

			my $distance = distance(calcPosition($char), calcPosition($player));

			# Need to walk to the target if out of range so that we can cast the skill --
			# but only when we're not a dedicated follower. ai_route() here doesn't clear
			# or coordinate with an active `follow` task, so on a follower it fights the
			# core follow logic for movement control: it can drag the character off its
			# path toward the master (who may be moving in a completely different
			# direction), causing it to lose sight of the master and fall into follow's
			# own "lost master" recovery (climbing lost_stuck) while this loop keeps
			# trying to reach its own, possibly also-moving, target. On a follower, skip
			# the detour and just let the skill_use attempt below fail/timeout normally
			# (bounded by maxAttempts) -- natural follow drift will bring us in range if
			# the target is actually nearby the party.
			if ($distance > 8 && !$config{follow}) {
				my $targetPos = calcPosition($player);
				ai_route(
					$field->baseName,
					$targetPos->{x},
					$targetPos->{y},
					distFromGoal => 4,
				);
			}

			my $skill = Skill->new(auto => "Soul Change");
			ai_skillUse2($skill, 1, undef, undef , $player);
			$attempts++;
		}
	}
}

sub insert {
	my $name = shift;

	my %priorityHash = getPriority();
	my $priority = $priorityHash{$name};
	$priority = 999 if !defined $priority;

	my $el = {
		name => $name,
		priority => $priority,
	};

	foreach my $q (@{$prioQueue}) {
		if ($q->{name} eq $el->{name}) {
			return;
		}
	}

	push(@{$prioQueue}, $el);

	# reset timer so processSoulChange can act immediately after insert
	my $timeout = $config{soulChange_timeout} || 5;
	$timer = time - $timeout;

	my $i = scalar(@{$prioQueue}) - 1;
	while ($i > 0 && $prioQueue->[$i]{priority} < $prioQueue->[$i - 1]{priority}) {
		# swap
		my $temp = $prioQueue->[$i];
		$prioQueue->[$i] = $prioQueue->[$i - 1];
		$prioQueue->[$i - 1] = $temp;

		$i--;
	}
}

sub remove {
	return if scalar(@{$prioQueue}) == 0;
	my $name = shift;

	my $index = -1;
	for (my $i = 0; $i < scalar(@{$prioQueue}); $i++) {
		$index = $i if $prioQueue->[$i]{name} eq $name;
	}

	if ($index != -1) {
		splice(@{$prioQueue}, $index, 1);
	} else {
		shift @{$prioQueue}; # should not happen
	}
}

sub parsePriority {
	my $priorityStr = shift;
	my @priorityArr = split / *, */, $priorityStr;

	for my $i (0 .. $#priorityArr) {
		$priorityHash{$priorityArr[$i]} = $i;
	}
}

sub getPriority {
	if ($config{soulChange_priority} && scalar(keys(%priorityHash)) == 0) {
		parsePriority($config{soulChange_priority});
	}

	return %priorityHash;
}

sub onSkillUse {
	return unless $config{soulChange};

	my (undef, $args) = @_;

	if ($args->{skillID} == 374 && $args->{sourceID} eq $accountID) {
		$attempts = 0;
		my $player = $playersList->getByID($args->{targetID});
		message "[soulChange] successfully casted soul change on $player->{name}\n", "plugin";
		remove($player->{name});
	}
}

sub queueString {
	my $sep = "";
	my $str = "";
	foreach my $q (@{$prioQueue}) {
		$str .= $sep . $q->{name};
		$sep = ", ";
	}

	return $str;
}

1;
