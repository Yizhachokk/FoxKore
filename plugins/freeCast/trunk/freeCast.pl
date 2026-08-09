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
        
        # Додаємо перевірку на wait4party
        if ($config{'wait4party'}) {
            my $followTarget = AI::ai_getFollowTarget();
            if ($followTarget) {
                my $followPos = $followTarget->{pos_to};
                my $distanceToFollow = distance($myPos, $followPos);
                
                # Якщо відстань більша за мінімальну, пересуваємося ближче
                if ($distanceToFollow > $config{'followDistanceMin'}) {
                    AI::ai_route(
                        $field->baseName,
                        $followPos->{x},
                        $followPos->{y},
                        attackOnRoute => $config{'attackAuto'}
                    );
                }
            }
        }

        # Перевірка на використання вмінь
        if ($s eq "MG_FIREBOLT" || $s eq "MG_COLDBOLT" || $s eq "MG_LIGHTNINGBOLT" || $s eq "PF_SOULCHANGE" || $s eq "MG_LIGHTNINGBOLT" || 
            $s eq "MG_THUNDERSTORM" || $s eq "PF_HPCONVERSION" || $s eq "EFST_ENERGYCOAT" || 
            $s eq "MG_ENERGYCOAT") {
            cast();
        }
    }
    # Автоматична активація ненаправлених скілів
    useNonTargetSkills();
}


sub useNonTargetSkills {
    # Перевірка активності кожного ненаправленого скіла
    if ($char->{skills}{PF_HPCONVERSION}{lv} && !$char->{statuses}{PF_HPCONVERSION}) {
        message "Using HP Conversion skill\n";
        $char->useSkill($char->{skills}{PF_HPCONVERSION}{handle});
    }

    if ($char->{skills}{EFST_ENERGYCOAT}{lv} && !$char->{statuses}{EFST_ENERGYCOAT}) {
        message "Using Energy Coat skill\n";
        $char->useSkill($char->{skills}{EFST_ENERGYCOAT}{handle});
    }

    if ($char->{skills}{MG_ENERGYCOAT}{lv} && !$char->{statuses}{MG_ENERGYCOAT}) {
        message "Using MG Energy Coat skill\n";
        $char->useSkill($char->{skills}{MG_ENERGYCOAT}{handle});
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
            # Логіка втечі від монстра
        } elsif ($config{'runFromTargetFree'} && ($realMonsterDist > $config{'runFromTargetFree_max'})) {
            # Логіка наближення до монстра
        }

    }
    $timeout{time} = time;
    $timeout{timeout} = 1;
}

return 1;
