package freeCast;

# This plugin is licensed under the GNU GPL
# Copyright 2008 by DInvalid
# Portions Copyright 2005 by kaliwanagan
# --------------------------------------------------
# Experimental! Use on your own risk!
# How to install this thing..:
#
# The plugin will activate if:
# you have the skill free cast at level 1 or higher, and
# config is set:
# runFromTargetFree 1
# runFromTargetFree_min 7
# runFromTargetFree_mid 9
# runFromTargetFree_max 12
#
# Moved here from plugins/freeCast/trunk/freeCast.pl -- that path sat two
# directory levels below plugins/, past the plugin loader's one-level-deep
# recursion (src/Plugins.pm's getFilesFromDirs, recurse_lv=1), so this
# plugin was never actually being loaded regardless of config.txt. Every
# other plugin under this same trunk/-nested layout lives under
# plugins/needs-review/ (deliberately excluded); this was the one exception.
#
# The runFromTargetFree_min/_max kiting logic below (move away when the
# monster's too close, move closer when it's too far) was also missing here
# -- restored from plugins/needs-review/freeCast/trunk/freeCast.pl (the
# stock version) since the working copy had it stripped down to empty
# comment placeholders. The follow-catchup check (route to the follow target
# if it falls behind during a cast) is this project's own addition on top of
# stock. Self-skill casting (Indulge, Energy Coat, etc.) belongs in
# config.txt's own useSelf_skill blocks (see account/03sage/config.txt) --
# NOT here. This plugin used to also duplicate that via a useNonTargetSkills
# sub, which fought with the config.txt blocks over the same skills and
# caused runaway re-casting; that sub was removed. src/AI/CoreLogic.pm's
# processAutoSkillUse already runs useSelf_skill checks during route/
# mapRoute/follow, so config.txt's own timeout/whenStatusInactive handles
# "cast this while walking" without any plugin help.

use strict;
use Plugins;
use Globals;
use Translation qw(T TF);
use Log qw(message warning error);
use AI;
use Skill;
use Misc;
use Network;
use Network::Send;
use Utils;
use Math::Trig;
use Utils::Benchmark;
use Utils::PathFinding;


Plugins::register('Free Cast', 'experimental sage free cast support', \&Unload);
my $hook1 = Plugins::addHook('AI_post', \&call);
my $ID;
my $target;
my %timeout;
my %followCatchupTimeout;
my ($myPos, $monsterPos,$monsterDist);

##
# round($number)
#
# Returns the rounded number
sub round {
	my($number) = shift;
	return int($number + .5 * ($number <=> 0));
}


sub Unload {
	Plugins::delHook('AI_post', $hook1);
}

sub call {
    # This plugin is Sage/Free-Cast-specific, but as an OpenKore plugin it
    # loads for EVERY character (plugins aren't per-account like config.txt).
    # Without this guard, the wait4party follow-catchup block below would
    # fire for every `follow 1` character mid-any-skill-cast, not just Sages
    # with Free Cast -- injecting unwanted extra routing into every other
    # class's normal cast behavior. Bail out immediately for anyone who
    # doesn't actually have the skill.
    return unless $char->{skills}{SA_FREECAST}{lv};

    my $i = AI::findAction("attack");
    if (defined $i) {
        my $args = AI::args($i);
        $ID = $args->{ID};
        $target = Actor::get($ID);
        $myPos = $char->{pos_to};
        $monsterPos = $target->{pos_to};
        $monsterDist = round(distance($myPos, $monsterPos));
    }

    if (AI::action eq "skill_use") {
        my $args = AI::args(AI::action);
        my $s = $args->{skillHandle};
        my $routedToLeaderThisTick = 0;

        # Перевіряємо саме core-follow (follow 1), а не тумблер плагіна wait4party
        if ($config{'follow'}) {
            my $followTarget;
            foreach (keys %players) {
                if ($players{$_}{name} eq $config{followTarget}) {
                    $followTarget = $players{$_};
                    last;
                }
            }
            if ($followTarget) {
                my $followPos = $followTarget->{pos_to};
                my $distanceToFollow = distance($myPos, $followPos);

                # Якщо відстань більша за мінімальну, пересуваємося ближче --
                # але не частіше ніж followCatchupTimeout: AI_post викликається
                # щотика (ai_attack_main/ai), а useSelf_skill-и на кшталт
                # Indulge можуть тримати AI::action() eq "skill_use" довше за
                # один тік. Без цього throttle цей unshift ai_route() виконувався
                # б щотика, поки триває каст, ховаючи під собою щойно
                # запущений skill_use ще до того, як він хоч раз відпрацював --
                # і навпаки, наступний перезапит Indulge ховав би цей route.
                # Результат -- нескінченно зростаюча @ai_seq (route, skill_use,
                # route, skill_use, ...), а не справжній рух до лідера.
                if ($distanceToFollow > $config{'followDistanceMin'} && main::timeOut(\%followCatchupTimeout)) {
                    AI::ai_route(
                        $field->baseName,
                        $followPos->{x},
                        $followPos->{y},
                        attackOnRoute => $config{'attackAuto'}
                    );
                    $routedToLeaderThisTick = 1;
                    $followCatchupTimeout{time} = time;
                    $followCatchupTimeout{timeout} = 1;
                }
            }
        }

        # Перевірка на використання вмінь -- пропускаємо кайтинг, якщо цього
        # тіку вже запущено route до лідера (обидва можуть видати команду
        # руху й "боротися" одне з одним, якщо запустити разом)
        if (!$routedToLeaderThisTick && (
            $s eq "MG_FIREBOLT" || $s eq "MG_COLDBOLT" || $s eq "MG_LIGHTNINGBOLT" || $s eq "PF_SOULCHANGE" ||
            $s eq "MG_THUNDERSTORM" || $s eq "PF_HPCONVERSION" || $s eq "EFST_ENERGYCOAT" ||
            $s eq "MG_ENERGYCOAT")) {
            cast();
        }
    }
}

sub cast {
    if (($char->{skills}{SA_FREECAST}{lv}) && main::timeOut(\%timeout)) {

        my ($realMyPos, $realMonsterPos, $realMonsterDist, $hitYou);
        my $realMyPos = calcPosition($char);
        my $realMonsterPos = calcPosition($target);
        my $realMonsterDist = round(distance($realMyPos, $realMonsterPos));

        $myPos = $realMyPos;
        $monsterPos = $realMonsterPos;
        $hitYou = 0;

        if ($config{'runFromTargetFree'} && ($realMonsterDist < $config{'runFromTargetFree_min'})) {
            my @blocks = $field->calcRectArea($myPos->{x}, $myPos->{y}, $config{'runFromTargetFree_mid'});

            my $highest;
            foreach (@blocks) {
                my $dist = ord(substr($field->{dstMap}, $_->{y} * $field->{width} + $_->{x}));
                if (!defined $highest || $dist > $highest) {
                    $highest = $dist;
                }
            }
            my $pathfinding = new PathFinding;
            use constant AVOID_WALLS => 4;
            for (my $i = 0; $i < @blocks; $i++) {
                # We want to avoid walls (so we don't get cornered), if possible
                my $dist = ord(substr($field->{dstMap}, $blocks[$i]{y} * $field->{width} + $blocks[$i]{x}));
                if ($highest >= AVOID_WALLS && $dist < AVOID_WALLS) {
                    delete $blocks[$i];
                    next;
                }

                $pathfinding->reset(
                    field => $field,
                    start => $myPos,
                    dest => $blocks[$i]
                );
                my $ret = $pathfinding->runcount;
                if ($ret < 0 || $ret > $config{'runFromTargetFree_min'} * 2) {
                    delete $blocks[$i];
                    next;
                }

                delete $blocks[$i] unless ($field->checkLOS($blocks[$i], $realMonsterPos, 1));
            }

            my $largestDist;
            my $best_spot;
            foreach (@blocks) {
                next unless defined $_;
                my $dist = distance($monsterPos, $_);
                if (!defined $largestDist || $dist > $largestDist) {
                    $largestDist = $dist;
                    $best_spot = $_;
                }
            }

            $char->move($best_spot->{x}, $best_spot->{y}, $ID) if ($best_spot);

        } elsif ($config{'runFromTargetFree'} && ($realMonsterDist > $config{'runFromTargetFree_max'})) {
            my $radius = $config{runFromTargetFree_max} - 1;
            my @blocks = calcRectArea2($realMonsterPos->{x}, $realMonsterPos->{y},
                $radius,
                $config{runFromTargetFree_mid});

            my $best_spot;
            my $best_dist;
            for my $spot (@blocks) {
                if (
                    $field->isWalkable($spot->{x}, $spot->{y}) &&
                    $field->checkLOS($spot, $realMonsterPos, $config{attackCanSnipe})
                ) {
                    my $dist = distance($realMyPos, $spot);
                    if (!defined($best_dist) || $dist < $best_dist) {
                        $best_dist = $dist;
                        $best_spot = $spot;
                    }
                }
            }

            $char->move($best_spot->{x}, $best_spot->{y}, $ID) if ($best_spot);
        }

    }
    $timeout{time} = time;
    $timeout{timeout} = 1;
}

return 1;
