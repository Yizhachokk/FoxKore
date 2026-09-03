########################################
# partyGuard -- unified party wait/rescue/cast-wait plugin
#
# Merges the useful behaviors of wait4party, betterLeader and the (never-installed)
# defendParty into one plugin, plus a new "run to help a fighting party member" reflex
# none of the three fully covered on their own.
#
# This software is open source, licensed under the GNU General Public License, version 3.
#
=pod
	--- BEHAVIOR (priority order, evaluated every tick / on each relevant packet)
	1. A visible party member is attacking a monster, or is being attacked by one,
	   and the hero itself is not currently fighting anything -> hero attacks that
	   same monster (rescue/assist), interrupting whatever it was doing.
	2. A visible party member is casting a skill (and the hero isn't already
	   rescuing/fighting, and is currently routing somewhere) -> hero pauses for a
	   configurable percentage of that skill's cast time, then resumes.
	3. A party member is NOT visible (off-screen, same map or a different one) ->
	   hero routes toward their last known position to reconnect (sit-and-wait is
	   available as an opt-in alternative, see partyGuard_waitBySitting). Once they
	   come back into sight, the hero keeps closing in on their live position --
	   it does NOT stop the instant they're merely on-screen -- until within
	   followDistanceMin cells, same as core's own follow logic.
	4. A visible party member is idle (not fighting, not casting) -> hero does
	   nothing special and continues whatever it was already doing.

	--- CONFIGURATION (config.txt)
	partyGuard [0|1]
	  Master on/off switch. Default 0.

	partyGuard_rescue [0|1]
	  Enable the "help a fighting party member" reflex. Default 1.

	partyGuard_rescueMaxDistance [cells]
	  Don't try to assist a party member fighting further away than this. Default 20.

	partyGuard_castWaitPercent [0-100+]
	  How much of a party member's cast time to pause movement for, as a percentage
	  of the skill's total cast time. 100 = wait out the full cast, 60 = wait 60% of
	  it then start moving again, 0 = don't wait at all (disables cast-waiting).
	  Default 50 (wait half the cast, same as the original wait4party behavior).

	partyGuard_castIgnore [comma-separated skill names]
	  Skills to never wait for, even if partyGuard_castWaitPercent > 0.

	partyGuard_waitBySitting [0|1]
	  When a party member goes out of sight, sit and wait instead of routing to
	  find them. Default 0 (route to find them).

	partyGuard_sameMapOnly [0|1]
	  Only try to reconnect with a missing party member if they're still on the
	  same map. Default 0.

	partyGuard_attackOnSearch [0|1|2]
	  0 = don't attack monsters encountered while routing to find a missing party
	  member; 1 = retaliate only; 2 = always attack. Default 0.

	partyGuard_approachDistance [cells]
	  How close to get to a party member once they're back in sight, while
	  reconnecting after they went missing. Deliberately NOT tied to
	  followDistanceMin -- that's often 0 or 1 on this project's accounts,
	  which made the hero try to path onto the party member's own tile and
	  spam "closing in" forever since it could never actually get that close
	  (another character can't stand on an occupied tile). Default 3 (close
	  enough to reconnect, not right on top of them).

	partyGuard_timeout [seconds]
	  Grace period after a party member goes missing before the hero starts
	  routing toward them (or sitting, if partyGuard_waitBySitting is set).

	partyGuard_followSit [0|1]
	  Sit down when a visible party member sits. ATTENTION: turn off
	  'followSitAuto' on this character or it may sit forever waiting on itself.

	partyGuard_ignore [comma-separated player names]
	  Party members to fully ignore for every behavior above.

	partyGuard_showMsg [0|1]
	  Print extra console messages for debugging.

	--- EXAMPLE config.txt
	partyGuard 1
	partyGuard_rescue 1
	partyGuard_rescueMaxDistance 20
	partyGuard_castWaitPercent 50
	partyGuard_castIgnore
	partyGuard_waitBySitting 0
	partyGuard_sameMapOnly 0
	partyGuard_attackOnSearch 1
	partyGuard_approachDistance 3
	partyGuard_timeout 1.5
	partyGuard_followSit 0
	partyGuard_ignore
	partyGuard_showMsg 0
=cut
###########

package partyGuard;

use strict;

use Plugins;
use Globals qw(%config @partyUsersID $playersList $monstersList $accountID $char $field %ai_v %timeout $taskManager);
use Utils qw(distance timeOut);
use Utils::DataStructures qw(existsInList);
use Log qw(message warning error debug);
use Translation qw/T TF/;
use Misc qw(isCellOccupied);
use AI;

use constant { NAME => 'partyGuard' };

my %findParty;
my %partySit;
my %chaseParty; # throttles the "in sight but not close yet" re-route below
my @notAI = qw(storageAuto storageGet sellAuto buyAuto attack skill_use);

Plugins::register(NAME, 'Unified party wait/rescue/cast-wait plugin', \&unload, \&unload);
my $hooks = Plugins::addHooks(
	['AI_pre',       \&waitForOthers, undef],
	['packet_attack', \&onPacketAttack, undef],
	['is_casting',   \&waitCast, undef],
);

sub unload {
	Plugins::delHooks($hooks);
	undef %findParty;
	undef %partySit;
	undef %chaseParty;
}

# ------------------------------------------------------------------
# Find the nearest walkable, unoccupied cell to (x,y) on the CURRENT map,
# searching outward ring by ring. Other party members routing to the same
# lost/rescued teammate all converge on that teammate's exact tile, which
# another hero may already be standing on -- a route straight onto an
# occupied cell either gets silently rejected by the server or leaves the
# character bumping into the obstacle forever. Only usable for on-map
# checks (needs $field to already be the target's map); callers on a
# different map should skip this and route as before.
# ------------------------------------------------------------------
sub find_free_cell_near {
	my ($x, $y, $maxRadius) = @_;
	$maxRadius = 5 unless defined $maxRadius;

	return { x => $x, y => $y }
		if ($field->isWalkable($x, $y) && !isCellOccupied({ x => $x, y => $y }, $char));

	for my $radius (1 .. $maxRadius) {
		for my $dx (-$radius .. $radius) {
			for my $dy (-$radius .. $radius) {
				next unless (abs($dx) == $radius || abs($dy) == $radius); # ring edge only
				my ($cx, $cy) = ($x + $dx, $y + $dy);
				next unless $field->isWalkable($cx, $cy);
				next if isCellOccupied({ x => $cx, y => $cy }, $char);
				return { x => $cx, y => $cy };
			}
		}
	}

	# Nothing free nearby -- fall back to the original point rather than
	# refusing to route at all; the route/approach-distance logic downstream
	# will still stop short of it as usual.
	return { x => $x, y => $y };
}

# ------------------------------------------------------------------
# Behavior 3 & 4: reconnect with a missing party member, or follow-sit.
# Adapted from wait4party.pl's waitForOthers (proven, tested logic),
# config keys renamed to the partyGuard_* namespace.
# ------------------------------------------------------------------
sub waitForOthers {
	return unless ($config{partyGuard} && @partyUsersID);

	my $actor;
	foreach (@partyUsersID) {
		next if (!$_ || $_ eq $accountID
		  || ($config{partyGuard_ignore} && existsInList("$config{partyGuard_ignore}", "$char->{'party'}{'users'}{$_}{'name'}"))
		  || ($findParty{ID} && $findParty{ID} ne $_)); # first lost first served
		$actor = $playersList->getByID($_);

		# PARTY MISSING!!
		if (!$actor && $char->{'party'}{'users'}{$_}{'online'}) {
			my %party;
			$party{x} = $char->{party}{users}{$_}{pos}{x};
			$party{y} = $char->{party}{users}{$_}{pos}{y};
			($party{map}) = $char->{party}{users}{$_}{map} =~ /([\s\S]*)\.gat/;

			if ($party{map} ne $field->baseName() || !$party{'x'} || !$party{'y'}
			  || ($party{'x'} == 0) || ($party{'y'} == 0)) {
				next if $config{partyGuard_sameMapOnly};
				return unless timeOut($timeout{ai}{time}, 5);

				delete $party{x};
				delete $party{y};
			}

			next unless ($party{map} ne $field->baseName || exists $party{x});

			if (!$findParty{ID}) {
				$findParty{ID} = $_;
				$findParty{time} = time if !$findParty{time};
				$findParty{timeout} = $config{partyGuard_timeout} if ($config{partyGuard_timeout});

				if ($config{partyGuard_waitBySitting}) {
					warning ("Party (".$char->{party}{users}{$_}{name}.") lost, wait by sitting.\n", NAME);
				} else {
					warning ("Party (".$char->{party}{users}{$_}{name}.") lost.\n", NAME);
				}
			}

			return if AI::inQueue(@notAI);
			if ($config{partyGuard_waitBySitting}) {
				emulateCmdSit() if (!$char->{sitting});
				return if (!$findParty{timeout});   # wait by sit forever..
			}
			return if ($findParty{timeout} && !timeOut(\%findParty));

			# Search for Party
			if ((exists $ai_v{party} && distance(\%party, $ai_v{party}) > $config{followDistanceMax})
			  || ($party{map} ne $ai_v{party}{map})
			  || ($ai_v{party}{time} && timeOut($ai_v{party}{time}, 15) && distance(\%party, $char->{pos_to}) > $config{followDistanceMax})) {
				$ai_v{party}{x} = $party{x};
				$ai_v{party}{y} = $party{y};
				$ai_v{party}{map} = $party{map};
				$ai_v{party}{time} = time;

				if ($ai_v{party}{map} ne $field->baseName) {
					message TF("[partyGuard] Calculating route to find %s: %s\n", $char->{party}{users}{$_}{name}, $ai_v{party}{map}), NAME;
				} elsif (distance(\%party, $char->{pos_to}) > $config{followDistanceMax}) {
					message TF("[partyGuard] Calculating route to find %s: %s (%d %d)\n", $char->{party}{users}{$_}{name}, $ai_v{party}{map}, $ai_v{party}{x}, $ai_v{party}{y}), NAME;
				} else {
					return;
				}

				AI::clear("move", "route", "mapRoute");
				my ($goal_x, $goal_y) = ($ai_v{party}{x}, $ai_v{party}{y});
				if ($ai_v{party}{map} eq $field->baseName) {
					my $free = find_free_cell_near($goal_x, $goal_y);
					($goal_x, $goal_y) = ($free->{x}, $free->{y});
				}
				AI::ai_route($ai_v{party}{map}, $goal_x, $goal_y, distFromGoal => $config{followDistanceMin}, attackOnRoute => $config{partyGuard_attackOnSearch});
				return;
			}

		# party member back in sight -- keep closing in on their live position
		# instead of stopping the instant they're merely visible
		} elsif ($findParty{ID} eq $_) {
			if (!$char->{'party'}{'users'}{$_}{'online'}) {
				%findParty = ();
				undef %chaseParty;
				warning TF("[partyGuard] Party member %s is offline\n", $char->{party}{users}{$_}{name}), NAME;
				AI::clear("route");
				return;
			}

			my $approachDist = defined($config{partyGuard_approachDistance}) ? $config{partyGuard_approachDistance} : 3;

			if ($actor && distance($char->{pos_to}, $actor->{pos_to}) <= $approachDist) {
				%findParty = (); ## undef findParty!!
				undef %chaseParty;
				Commands::cmdStand() if ($char->{sitting} && !$partySit{ID});
				message TF("[partyGuard] Party member %s found!\n", $char->{party}{users}{$_}{name}), NAME;
				AI::clear("move", "route", "mapRoute");
				return;
			}

			# still too far even though visible -- chase, re-aiming at their
			# current position every second rather than a stale one
			return if AI::inQueue(@notAI);
			return unless $actor;
			return if ($chaseParty{time} && !timeOut($chaseParty{time}, 1));
			$chaseParty{time} = time;

			message TF("[partyGuard] Party member %s in sight but %d cells away, closing in\n",
				$char->{party}{users}{$_}{name}, distance($char->{pos_to}, $actor->{pos_to})), NAME
				if $config{partyGuard_showMsg};

			AI::clear("move", "route", "mapRoute");
			my $free = find_free_cell_near($actor->{pos_to}{x}, $actor->{pos_to}{y});
			AI::ai_route($field->baseName, $free->{x}, $free->{y},
				distFromGoal => $approachDist, attackOnRoute => $config{partyGuard_attackOnSearch});
		## party sit?
		} elsif ($actor && $config{partyGuard_followSit} && !(AI::inQueue(@notAI)) && AI::action ne "sitAuto") {
			if ($actor->{sitting} && !$partySit{ID}) {
				emulateCmdSit() if (!$char->{sitting});
				warning TF("[partyGuard] Party member %s sit\n", $actor->{name}), NAME;
				$partySit{ID} = $actor->{ID};
				$partySit{time} = time;
				$partySit{timeout} = 10;

			} elsif ($partySit{ID} && $actor->{ID} eq $partySit{ID} && timeOut(\%partySit)) {
				if ($actor->{sitting}) {
					emulateCmdSit() if (!$char->{sitting});
					$partySit{'time'} = time;
					$partySit{'timeout'} = 5;

				} elsif (!$actor->{sitting}) {
					Commands::cmdStand();
					message TF("[partyGuard] Party member %s stand\n", $actor->{name}), NAME;
					%partySit = ();
					return;
				}

				if (!$char->{'party'}{'users'}{$_}{'online'}) {
					Commands::cmdStand();
					warning TF("[partyGuard] Party member %s is offline\n", $actor->{name}), NAME;
					%partySit = ();
					return;
				}
			}
		}
	}
	return;
}

# ------------------------------------------------------------------
# Behavior 1: rescue/assist a party member in combat.
# Generalized from account/hunting/defendparty.txt's onPacketAttack
# (which only reacted for a fixed list of "protected" names and only
# retargeted an already-running attack) to work for any party member
# and to also engage from idle, not just retarget.
# ------------------------------------------------------------------
sub onPacketAttack {
	return unless ($config{partyGuard} && $config{partyGuard_rescue} && @partyUsersID);
	return if AI::inQueue("attack"); # hero already fighting something -- don't interrupt

	my (undef, $args) = @_;
	my $sourceID = $args->{sourceID};
	my $targetID = $args->{targetID};
	return unless ($sourceID && $targetID);
	return if ($sourceID eq $accountID || $targetID eq $accountID); # that's the hero's own fight

	my %partySet = map { $_ => 1 } @partyUsersID;

	my ($allyID, $monsterID);
	if ($partySet{$sourceID} && $monstersList->getByID($targetID)) {
		# ally is attacking a monster -> help finish it off
		($allyID, $monsterID) = ($sourceID, $targetID);
	} elsif ($partySet{$targetID} && $monstersList->getByID($sourceID)) {
		# ally is being attacked -> defend them
		($allyID, $monsterID) = ($targetID, $sourceID);
	} else {
		return;
	}

	return if ($config{partyGuard_ignore} && existsInList("$config{partyGuard_ignore}", "$char->{'party'}{'users'}{$allyID}{'name'}"));

	my $monster = $monstersList->getByID($monsterID);
	return unless $monster;

	my $maxDist = defined($config{partyGuard_rescueMaxDistance}) ? $config{partyGuard_rescueMaxDistance} : 20;
	return if (distance($char->{pos_to}, $monster->{pos_to}) > $maxDist);

	message TF("[partyGuard] Party member %s is fighting %s -- assisting\n",
		$char->{party}{users}{$allyID}{name}, $monster->{name}), NAME;

	AI::clear("move", "route", "mapRoute");
	$char->attack($monsterID);
}

# ------------------------------------------------------------------
# Behavior 2: pause for a configurable percentage of a party member's cast time.
# Same math as wait4party.pl's waitCast, generalized from a hardcoded 50%
# into partyGuard_castWaitPercent, and from an opt-in skill whitelist into
# an opt-out skill list (partyGuard_castIgnore).
# ------------------------------------------------------------------
sub waitCast {
	return unless ($config{partyGuard}
	  && @partyUsersID
	  && AI::action eq "route" && !AI::inQueue("attack"));

	my (undef, $actor) = @_;
	return unless ($actor && $actor->{sourceID} && $actor->{skill});

	my $percent = $config{partyGuard_castWaitPercent};
	$percent = 50 unless defined $percent;
	return if $percent <= 0;

	return if ($config{partyGuard_castIgnore} && existsInList($config{partyGuard_castIgnore}, $actor->{skill}->getName()));

	foreach (@partyUsersID) {
		next if (!$_ || $_ ne $actor->{sourceID} || $_ eq $accountID
		  || ($config{partyGuard_ignore} && existsInList("$config{partyGuard_ignore}", "$char->{'party'}{'users'}{$_}{'name'}")));

		my $wait = $actor->{castTime} * ($percent / 100) * 0.001;
		warning TF("[partyGuard] Party member %s is casting %s, wait %.1f seconds\n",
			$char->{party}{users}{$_}{name}, $actor->{skill}->getName(), $wait), NAME;

		# can't find better idea to suspend AI other than this (same trick as wait4party)
		AI::clear("clientSuspend");
		AI::ai_clientSuspend(0, $wait);
		return;
	}
}

# Copied from Commands::cmdSit / wait4party.pl's emulateCmdSit.
sub emulateCmdSit {
	$ai_v{sitAuto_forcedBySitCommand} = 1;
	AI::clear("move", "route", "mapRoute");
	AI::clear("attack") unless AI::ai_getAggressives(1, 1);
	require Task::SitStand;
	my $task = new Task::ErrorReport(
		task => new Task::SitStand(
			actor => $char,
			mode => 'sit',
			priority => Task::USER_PRIORITY
		)
	);
	$taskManager->add($task);
	$ai_v{sitAuto_forceStop} = 0;
}

1;
