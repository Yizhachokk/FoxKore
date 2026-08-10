#########################################################################
#  OpenKore - Portal actor object
#  Copyright (c) 2005 OpenKore Team
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision: 3869 $
#  $Id: Player.pm 3869 2006-02-02 12:10:15Z hongli $
#
#########################################################################
##
# MODULE DESCRIPTION: Portal actor object
#
# All members in %portals are of the Actor::Portal class.
#
# @MODULE(Actor) is the base class for this class.
package Actor::Portal;

use strict;
use Actor;
use base qw(Actor);
use Globals qw($messageSender);
use Translation qw(T);

sub new {
	my ($class) = @_;
	return $class->SUPER::new(T('Portal'));
}

# Some servers script a portal to also require an NPC-style talk/response
# sequence before it takes effect (e.g. an airship boarding confirmation).
# Task::TalkNPC treats any actor found via portalsList the same as an NPC
# once a talk sequence is defined for it (see tables/portals.txt's optional
# [cost] [steps] fields), so it needs the same sendTalk() entry point.
sub sendTalk {
	my ($self) = @_;

	$messageSender->sendTalk($self->{ID});
}

1;
