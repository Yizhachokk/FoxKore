##############################
# =======================
# routeUseRespawn
# =======================
# This plugin is licensed under the GNU GPL
# Created by yizhachok
#
# What it does: scans route for maps we can @go to. If there is, we @go to them
#
# Config key (put in config.txt):
#	route_routeUseRespawn 1
# 
# No source mod needed -- src/Task/CalcMapRoute.pm's iterate() already calls
# Plugins::callHook('FullSolutionReady', { route => ..., fullRoute => ... })
# right where this file's header used to say to add a 'MapSolutionReady'
# hook. That hook name was never added to core (only exists in this
# comment), so this plugin silently never fired at all until it was
# pointed at the hook core actually calls.
#
###############################################
package routeUseRespawn;

use strict;
use Plugins;
use Globals;
use Utils;
use Misc;
#use AI;
use Log qw(debug message warning error);
use Translation;
use Data::Dumper;

use List::Util qw(shuffle);

Plugins::register('routeUseRespawn', 'Automatically uses respawn command if a saveMap is in the route', \&onUnload);

my $hooks = Plugins::addHooks(
	['FullSolutionReady',			\&getRoute],
);

message "routeUseRespawn success\n", "success";

# The plugin now uses the `saveMap` config setting instead of a hardcoded
# %maps whitelist. Set `saveMap` in your config (e.g. `saveMap yuno`).

# Maps to ignore — do not trigger respawn when these appear in the route
my %exclude_maps = map { $_ => 1 } (
	'aldeba_in', 'alberta_in', 'ama_in01', 'ayo_in01', 'cmd_in01', 'ein_in01',
	'geffen_in', 'hu_in01', 'izlude_in', 'lhz_in03', 'lhz_in02', 'lou_in02',
	'xmas_in', 'mosk_in', 'payon_in02', 'payon_in01', 'prt_in', 'ra_in01',
	'um_in', 've_in', 'yuno_in01'
);

sub onUnload {
	Plugins::delHooks($hooks);
}

sub onReload {
    &onUnload;
}

sub getRoute {
	return unless ($config{'saveMap'});

	my (undef, $args) = @_;
	return unless $args && defined $args->{route};

	my @route = split(' -> ', $args->{route});
	my $destination = $route[$#route]; # get the destination

	debug sprintf("routeUseRespawn: received route='%s', destination='%s', current_field='%s', saveMap='%s'\n",
		$args->{route} // '', $destination // '', (defined $field && $field->baseName) ? $field->baseName : 'undef', $config{'saveMap'} // ''),
		"routeUseRespawn";

	# If we're currently on an excluded map, don't trigger respawn
	if (defined $field && $field->baseName) {
		my $current_lc = lc $field->baseName;
		if (exists $exclude_maps{$current_lc}) {
			debug sprintf("routeUseRespawn: current field '%s' is excluded -> skipping respawn\n", $field->baseName), "routeUseRespawn";
			return;
		}
		# Data-driven check (tables/no_teleport_maps.txt) -- catches shop/guild/instance
		# maps that block the Return-type teleport `do respawn` needs, even when they're
		# not in the hardcoded %exclude_maps list above. Without this, Task::Teleport::Respawn
		# still tries to use the Butterfly Wing/skill, the server silently rejects it, and the
		# bot sits stuck instead of walking out normally.
		if (Misc::isReturnTeleportBlockedOnMap($field->baseName)) {
			debug sprintf("routeUseRespawn: current field '%s' blocks return-teleport (no_teleport_maps.txt) -> skipping respawn\n", $field->baseName), "routeUseRespawn";
			return;
		}
	}

	my $step;
	my $save_map = lc $config{'saveMap'};
	while(@route)
	{
		$step = pop(@route);

		last if(lc $field->baseName eq lc $destination); # if for whatever reason we're at the dest, don't respawn

		my $step_lc = lc $step;
		$step_lc =~ s/^\s+|\s+$//g;

		debug sprintf("routeUseRespawn: testing step='%s' -> '%s' (save_map='%s')\n", $step, $step_lc, $save_map), "routeUseRespawn";

		# Skip excluded maps
		next if exists $exclude_maps{$step_lc};

		next unless ($step_lc eq $save_map); # not the saved map
		next if (lc $field->baseName eq $save_map); # don't respawn if it's the map we're on

		debug "routeUseRespawn: matched save_map -> sending respawn\n", "routeUseRespawn";
		# Party chat (not "c"/public) so the whole party's PartyRespawnSignal
		# automacro (account/CityBaseConfig.txt) can react and respawn+
		# autostorage together instead of only this character shortcutting.
		sendMessage($messageSender, "p", "respawn");
		Commands::run("respawn");
		undef @route;
	}
}

1;
