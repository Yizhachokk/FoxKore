# bragiGive plugin.
# A simple queue for Bragi-style skill.
#
# This plugin listens for emote commands (for example: `doCommand e ic`) or
# party messages requesting Bragi and queues the sender for a Bragi cast.
#
# Gated ONLY on bragiGive 1 -- do NOT resurrect a "legacy soulChange 1 also
# enables this" fallback. That used to exist and broke account/03sage's Sage
# (soulChange 1 there is for the real Soul Change skill): bragiGive would
# also activate and queue BA_POEMBRAGI attempts on a character that doesn't
# have Bragi, flooding the AI queue with un-castable skill_use entries that
# starved out the legitimate PF_SOULCHANGE casts. Checked every account in
# this project -- account/08bragi (the actual Bard) already sets its own
# explicit bragiGive 1, so nothing relies on the old alias.
#
# available config:
#   bragiGive [1|0] - enable or disable the plugin.
#   bragiGive_minSPPercent [value] - minimum SP to cast the skill, default to 50 (percent).
#   bragiGive_timeout [value] - timeout for attempts, default to 5 (seconds).
#   bragiGive_priority [value] - priority for the queue, comma separated.
#   bragiGive_maxAttempts [value] - maximum number of attempts allowed, default to 2.
#   bragiGive_emotion [id,id...] - optional, comma-separated list of emotion IDs that should trigger (if omitted common triggers will apply)
#
# You can use this plugin with doCommand blocks in your config.txt. For example:
#  doCommand p I need bragi! {
#    partyAggressives > 0
#    sp < 20%
#    timeout 5
#  }
#doCommand e ic {
#	sp < 19%
#	timeout 5
##	disabled 0
#}

package bragiGive;

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

sub load {
	message "[bragiGive] plugin loaded. Enable with 'bragiGive 1'. Enable debug with 'bragiGive_debug 1'.\n", "plugin";
}

Plugins::register('bragiGive', 'Bragi responder: queue and cast Bragi on emote or message', \&load, \&unload);

my $hooks = Plugins::addHooks(
	['AI_pre', \&onAIPre, undef],
	['packet_partyMsg', \&onPartyMsg, undef],
	['packet_chat', \&onPartyMsg, undef],
	['packet_message', \&onPartyMsg, undef],
	['packet_publicMsg', \&onPartyMsg, undef],
	['packet_public', \&onPartyMsg, undef],
	['packet_party', \&onPartyMsg, undef],

	# PacketParser.pm fires every packet as 'packet/<handlerName>' (with a
	# slash), keyed by the sub name the packet is actually registered under
	# (see ServerType0.pm) -- not any of the guessed 'packet_xxx' names that
	# used to be listed here. Emotes (e.g. *Idea*) come in as packet '00C0',
	# handled by sub `emoticon`, so the real hook is 'packet/emoticon'. Every
	# 'packet_emot*'/'packet_action'/etc alias below was dead: none of them
	# ever matched, so onEmotion never actually ran.
	['packet/emoticon', \&onEmotion, undef],
	# Poem of Bragi is a no-damage buff, confirmed via packet '011A'/'09CB'
	# (sub `skill_used_no_damage`), not the damage-skill 'skill_use' packet.
	['packet/skill_used_no_damage', \&onSkillUse, undef],
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
	processBragiGive();
}

sub onPartyMsg {
	return unless $config{bragiGive};
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

	# Only handle explicit party requests for Bragi (e.g. "I need bragi!")
	# allow common variations and typos like "i nedd bragi!"
	if (defined $msg && $msg =~ /\b(?:need|nedd)\b.*\bbragi\b/i) {
		insert($user // $args->{MsgUser});
		return;
	}
}

sub onEmotion {
	return unless $config{bragiGive};

	my (undef, $args) = @_;

	# Extract raw emotion/text fields
	my $raw_emotion;
	my $raw_text;
	if (!defined $args) {
		return;
	} elsif (ref $args eq 'HASH') {
		$raw_emotion = $args->{emotion} // $args->{emot} // $args->{type} // $args->{action} // $args->{emotionID} // $args->{emotid} // $args->{id};
		$raw_text = $args->{raw} || $args->{Raw} || $args->{msg} || $args->{message} || $args->{text};
	} elsif (ref $args eq 'ARRAY') {
		$raw_emotion = $args->[1] // $args->[2];
		$raw_text = $args->[1] // $args->[2];
	} else {
		$raw_emotion = $args;
		$raw_text = $args;
	}

	# Decide whether this emotion matches configured/default triggers
	my $matches_emotion = 0;
	my $emotion_cfg = (defined $config{bragiGive_emotion} && $config{bragiGive_emotion} ne '') ? $config{bragiGive_emotion} : $config{soulChange_emotion};

	# normalize key(s) from raw_emotion or raw_text. A numeric raw_emotion (the
	# real case: packet/emoticon's `type` field, e.g. 5) is looked up in
	# %emotions_lut to also pull its short command alias(es) (5 => "ic"), since
	# tables/emotions.txt is the source of truth for which ID means what --
	# matching the bare number against a hardcoded "==42" (the *SP* emote) would
	# otherwise never recognize *Idea* (id 5, alias "ic") at all.
	my @emotion_keys;
	my $emotion_key;
	if (defined $raw_emotion) {
		if (!ref $raw_emotion && $raw_emotion =~ /^\d+$/) {
			push @emotion_keys, $raw_emotion;
			if (my $cmd = $emotions_lut{$raw_emotion}{command}) {
				push @emotion_keys, map { lc $_ } split /,/, $cmd;
			}
			$emotion_key = $raw_emotion;
		} else {
			my $s = $raw_emotion // '';
			$s =~ s/^\s+|\s+$//g;
			$s =~ s/^[^A-Za-z0-9]+//;
			$s =~ s/[^A-Za-z0-9]+$//;
			$s =~ s/^\*+//; $s =~ s/\*+$//;
			$emotion_key = lc $s;
			push @emotion_keys, $emotion_key;
		}
	} elsif (defined $raw_text) {
		if ($raw_text =~ /\*([^\*]{1,40})\*/) {
			my $em = $1; $em =~ s/^\s+|\s+$//g; $em =~ s/^\*+//; $em =~ s/\*+$//;
			$emotion_key = lc $em;
			$raw_emotion = $em;
			push @emotion_keys, $emotion_key;
		} elsif ($raw_text =~ /\b(ic|idea|bragi)\b/i) {
			$emotion_key = lc $1;
			$raw_emotion = $1;
			push @emotion_keys, $emotion_key;
		}
	}

	if (defined $emotion_cfg && $emotion_cfg ne '') {
		my %emHash = map { lc($_) => 1 } split / *, */, $emotion_cfg;
		$matches_emotion = 1 if grep { $emHash{$_} } @emotion_keys;
	} else {
		for my $k (@emotion_keys) {
			if ($k =~ /^\d+$/ && $k == 42) {
				$matches_emotion = 1;
			} elsif ($k =~ /^sp$/ || $k =~ /^sptime$/ || $k =~ /^e7$/ || $k =~ /^mp$/) {
				$matches_emotion = 1;
			} elsif ($k eq 'ic' || $k eq 'idea' || $k =~ /bragi/) {
				$matches_emotion = 1;
			}
			last if $matches_emotion;
		}
		$matches_emotion = 1 if (!$matches_emotion && defined $raw_text && $raw_text =~ /bragi/i);
	}

	if ($config{bragiGive_debug} || $config{soulChange_debug}) {
		message "[bragiGive] onEmotion raw='$raw_emotion' text='$raw_text' key='$emotion_key' matches=$matches_emotion\n", "debug";
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
		my $maxdist = $config{bragiGive_maxDistance} || $config{soulChange_maxDistance} || 8;
		if ($best && $bestd <= $maxdist) { $player = $best; }
	}

	if ($player) {
		insert($player->{name});
		return;
	}

	# no last-console fallback (onConsole removed)
}

sub processBragiGive {
	return unless $config{bragiGive};
	return unless scalar(@{$prioQueue}) > 0;
	return if $char->sp_percent() < ($config{bragiGive_minSPPercent} || $config{soulChange_minSPPercent} || 50);

	my $timeout = $config{bragiGive_timeout} || $config{soulChange_timeout} || 5;
	my $maxAttempts = $config{bragiGive_maxAttempts} || $config{soulChange_maxAttempts} || $defaultMaxAttempts;

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

			# Nudge one step toward the target instead of a full ai_route() -- ai_route()
			# queues a persistent pathfinding task that doesn't clear or coordinate with
			# an active `follow` task, so it fights the core follow logic for movement
			# control (same problem and same fix as plugins/soulChange/soulChange.pl).
			# $char->move() is the single-motion nudge core follow itself uses each tick,
			# so it doesn't compete with follow. We still attempt the cast right after
			# regardless of whether the step lands; maxAttempts/timeout below give up on
			# this target normally if it doesn't connect.
			# For Bragi, approach to minimum 3 tiles from the target.
			if ($distance > 3) {
				my $targetPos = calcPosition($player);
				$char->move($targetPos->{x}, $targetPos->{y});
			}

			my $skillName = $config{bragi_skill} || "BA_POEMBRAGI2#Poem of Bragi#";

			if (!defined $skillName || $skillName eq '') {
				message "[bragiGive] no skill configured (bragi_skill); skipping cast\n", "error";
				remove($target);
				$attempts = 0;
				return;
			}

			# Try several candidate identifiers: configured value, inner name from #...#, and plain name
			my @candidates = ($skillName);
			if ($skillName =~ /#([^#]+)#/) {
				my $inner = $1; push @candidates, $inner unless grep { $_ eq $inner } @candidates;
			}
			push @candidates, "Poem of Bragi" unless grep { $_ eq "Poem of Bragi" } @candidates;

			my $did_cast = 0;
			my $last_err;
			foreach my $cand (@candidates) {
				eval {
					my $skill = Skill->new(auto => $cand);
					die "No valid skill returned for '$cand'" unless $skill;
					ai_skillUse2($skill, 1, undef, undef , $player);
					$did_cast = 1;
				};
				if ($@) {
					$last_err = $@;
					next;
				}
				last if $did_cast;
			}

			if (!$did_cast) {
				chomp $last_err if defined $last_err;
				message "[bragiGive] failed to cast skill (tried: " . join(", ", @candidates) . ") on $target: " . ($last_err || "unknown") . "\n", "error";
				remove($target);
				$attempts = 0;
				return;
			}

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

		# debug: log queued player when debug enabled
		if ($config{bragiGive_debug} || $config{soulChange_debug}) {
			message "[bragiGive] queued $name (priority=$priority)\n", "plugin";
		}

		# reset timer so processBragiGive can act immediately after insert
	my $timeout = $config{bragiGive_timeout} || $config{soulChange_timeout} || 5;
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
	my $prio_cfg = $config{bragiGive_priority} || $config{soulChange_priority};
	if ($prio_cfg && scalar(keys(%priorityHash)) == 0) {
		parsePriority($prio_cfg);
	}

	return %priorityHash;
}

sub onSkillUse {
	return unless $config{bragiGive};

	my (undef, $args) = @_;

	# When we (this account) use a skill on a player, assume the buff/skill was applied
	# and remove them from the queue. This avoids hardcoding a skillID for Bragi.
	if (defined $args->{sourceID} && $args->{sourceID} eq $accountID && defined $args->{targetID}) {
		$attempts = 0;
		my $player = $playersList->getByID($args->{targetID});
		if ($player) {
			message "[bragiGive] successfully cast on $player->{name}\n", "plugin";
			remove($player->{name});
		}
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
