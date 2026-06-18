#
# Export To MusicIP
# (c) 2024 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::ExportToMusicIP::Settings;

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.exporttomusicip');
my $log = logger('plugin.exporttomusicip');

sub name {
	return 'PLUGIN_EXPORTTOMUSICIP';
}

sub page {
	return 'plugins/ExportToMusicIP/settings/settings.html';
}

sub prefs {
	return ($prefs, qw(useapcvalues musicip_hostname musicip_port musicip_timeout musicip_replaceextension musicip_lmsmusicpath musicip_mipmusicpath scheduledexports exporttime postscanexport mip_rating_threshold));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if (defined $paramRef->{'pref_exporttime'}) {
		$paramRef->{'pref_exporttime'} =~ s/^\s+|\s+$//g;
	}
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

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';

	# disable manual export if active export or lm scan
	$paramRef->{'activelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
	$paramRef->{'activemipexport'} = 1 if $prefs->get('ExportInProgress');
}

1;
