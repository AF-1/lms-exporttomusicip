# ExportToMusicIP::Settings
#
# (c) 2024 AF
#
# Based on the TS MIP module by (c) 2006 Erland Isaksson
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::ExportToMusicIP::Settings;

use strict;
use warnings;
use utf8;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.exporttomusicip');
my $log = logger('plugin.exporttomusicip');
my $plugin;

sub name {
	return 'PLUGIN_EXPORTTOMUSICIP';
}

sub page {
	return 'plugins/ExportToMusicIP/settings/settings.html';
}

sub prefs {
	return ($prefs, qw(useapcvalues musicip_hostname musicip_port musicip_timeout musicip_replaceextension musicip_lmsmusicpath musicip_mipmusicpath scheduledexports exporttime));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'exportnow'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Slim::Utils::Scheduler::add_task(\&Plugins::ExportToMusicIP::Plugin::initExport);
	} elsif ($paramRef->{'abortexport'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::ExportToMusicIP::Plugin::abortExport();
	} elsif ($paramRef->{'pref_autoexport'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;

			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::ExportToMusicIP::Plugin::exportScheduler();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $host = $paramRef->{host} || (Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport'));
	$paramRef->{'squeezebox_server_jsondatareq'} = 'http://' . $host . '/jsonrpc.js';

	# disable manual export if active export
	$paramRef->{'activelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
	$paramRef->{'activemipexport'} = 1 if $prefs->get('ExportInProgress');
}

1;
