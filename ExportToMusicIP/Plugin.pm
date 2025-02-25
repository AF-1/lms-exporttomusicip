# Export To MusicIP
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

package Plugins::ExportToMusicIP::Plugin;

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use LWP::UserAgent;
use Time::HiRes qw(time);
use Slim::Schema;

my $lastMusicIpDate = 0;
my $MusicIpExportStartTime = 0;
my $exportAborted = 0;
my $errors = 0;
my @songs = ();

my $prefs = preferences('plugin.exporttomusicip');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.exporttomusicip',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_EXPORTTOMUSICIP',
});
my $apc_enabled;

sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin(@_);

	if (main::WEBUI) {
		require Plugins::ExportToMusicIP::Settings;
		Plugins::ExportToMusicIP::Settings->new();
	}
	initPrefs();

	Slim::Control::Request::subscribe(\&_setPostScanCBTimer, [['rescan'], ['done']]);
}

sub postinitPlugin {
	my $class = shift;
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;

	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 2, \&exportScheduler);
	}
}

sub initPrefs {
	$prefs->init({
		musicip_hostname => 'localhost',
		musicip_port => 10002,
		musicip_timeout => $serverPrefs->get('remotestreamtimeout') || 15,
		exporttime => '04:17',
		export_lastday => '',
		lastMusicIpDate => 0,
	});

	$prefs->set('ExportInProgress', 0);
	$prefs->set('exportResult', 0);

	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'exporttime');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 65535}, 'musicip_port');

	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Pref for scheduled export changed. Resetting or killing timer.');
			exportScheduler();
		}, 'scheduledexports', 'exporttime');
}

sub initExport {
	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		main::INFOLOG && $log->is_info && $log->info('Cannot export. Active LMS scan detected.');
		return;
	}

	@songs = ();
	$MusicIpExportStartTime = time();
	$prefs->set('ExportInProgress', 1);
	$prefs->set('exportResult', 0);
	$exportAborted = 0;
	$errors = 0;

	# test MIP url. No use in proceeding if response = fail
	my $http = LWP::UserAgent->new;
	my $hostname = $prefs->get('musicip_hostname');
	my $port = $prefs->get('musicip_port');
	$http->timeout($prefs->get('musicip_timeout'));
	my $musiciptesturl = "http://$hostname:$port/api/cacheid";
	my $response = $http->get($musiciptesturl);
	if (!$response->is_success) {
		$log->error("Failed to call MusicIP at: $musiciptesturl. Please check if the MusicIP hostname/ip address and port in the plugin settings are correct and confirm that the MusicIP service is running and can be access via URL from this computer.");
		$errors++;
	}

	unless ($errors) {
		my $table = ($apc_enabled && $prefs->get('useapcvalues')) ? 'alternativeplaycount' : 'tracks_persistent';
		my $sql = "SELECT tracks_persistent.url, $table.playCount, $table.lastPlayed, tracks_persistent.rating FROM tracks_persistent,tracks";
		$sql .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled && $prefs->get('useapcvalues'));
		$sql .= " where tracks_persistent.urlmd5 = tracks.urlmd5 and ifnull(tracks.remote,0) = 0 and (tracks_persistent.lastPlayed is not null or tracks_persistent.rating > 0)";

		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare($sql);
		my ($url, $playCount, $lastPlayed, $rating);
		eval {
			$sth->execute();
			$sth->bind_columns(undef, \$url, \$playCount, \$lastPlayed, \$rating);
			while( $sth->fetch() ) {
				my $thisTrack->{'url'} = $url;
				if ($rating) {
					$thisTrack->{'rating'} = convertRating($rating);
				} else {
					$thisTrack->{'rating'} = 0;
				}
				$thisTrack->{'playcount'} = $playCount;
				$thisTrack->{'lastplayed'} = $lastPlayed;
				push @songs, $thisTrack;
			}
			$sth->finish();
		};
		if ($@) {
			$log->warn("SQL error: $DBI::errstr, $@");
			$errors++;
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Found '.scalar(@songs).' tracks with statistics.');
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('songs with stats = '.Data::Dump::dump(\@songs));

		foreach (@songs) {
			handleTrack($_);
			last if $exportAborted;
			main::idleStreams();
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('Done exporting: unlocking and closing');

		finishExport();
	}

	# export result: 1 = success, 2 = aborted, 3 = errors
	if ($exportAborted == 1) {
		$prefs->set('exportResult', 2);
		main::INFOLOG && $log->is_info && $log->info('Export aborted after '.(time() - $MusicIpExportStartTime).' seconds.');
	} elsif ($errors > 0) {
		$prefs->set('exportResult', 3);
		main::INFOLOG && $log->is_info && $log->info('Export completed (with errors) after '.(time() - $MusicIpExportStartTime).' seconds.');
	} else {
		$prefs->set('exportResult', 1);
		main::INFOLOG && $log->is_info && $log->info('Export successfully completed after '.(time() - $MusicIpExportStartTime).' seconds.');
		$prefs->set('lastMusicIpDate', $lastMusicIpDate);
	}

	$prefs->set('ExportInProgress', 0);
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 20, sub {$prefs->set('exportResult', 0);});
	$exportAborted = 0;
}

sub abortExport {
	if ($prefs->get('ExportInProgress') > 0) {
		$exportAborted = 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('Aborting export');
		return;
	}
}

sub handleTrack {
	my $track = shift;

	my $url = $track->{'url'};
	main::DEBUGLOG && $log->is_debug && $log->debug('track url = '.Data::Dump::dump($url));
	my $rating = $track->{'rating'};
	main::DEBUGLOG && $log->is_debug && $log->debug('track rating = '.Data::Dump::dump($rating));
	my $playCount = $track->{'playcount'};
	main::DEBUGLOG && $log->is_debug && $log->debug('track playCount = '.Data::Dump::dump($playCount));
	my $lastPlayed = $track->{'lastplayed'};
	main::DEBUGLOG && $log->is_debug && $log->debug('lastPlayed url = '.Data::Dump::dump($lastPlayed));

	if (!$url) {
		$log->warn("No url for track");
		$errors++;
		return;
	}

	my $hostname = $prefs->get('musicip_hostname');
	my $port = $prefs->get('musicip_port');
	$url = getMusicIpURL($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('musicip url = '.Data::Dump::dump($url));
	if ($rating && $rating > 0) {
		my $musicipurl = "http://$hostname:$port/api/setRating?song=$url&rating=$rating";
		my $http = LWP::UserAgent->new;
		$http->timeout($prefs->get('musicip_timeout'));
		my $response = $http->get($musicipurl);
		if ($response->is_success) {
			my $result = $response->content;
			chomp $result;

			if ($result && $result > 0) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Set Rating = $rating for $url");
			} else {
				$log->warn("Failure setting Rating = $rating for $url");
				$errors++;
			}
		} else {
			$log->warn("Failed to call MusicIP at: $musicipurl");
			$errors++;
		}
	}
	if ($playCount) {
		my $musicipurl = "http://$hostname:$port/api/setPlayCount?song=$url&count=$playCount";
		my $http = LWP::UserAgent->new;
		$http->timeout($prefs->get('musicip_timeout'));
		my $response = $http->get($musicipurl);
		if ($response->is_success) {
			my $result = $response->content;
			chomp $result;

			if ($result && $result > 0) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Set PlayCount = $playCount for $url");
			} else {
				$log->warn("Failure setting PlayCount = $playCount for $url");
				$errors++;
			}
		} else {
			$log->warn("Failed to call MusicIP at: $musicipurl");
			$errors++;
		}
	}
	if ($lastPlayed) {
		my $musicipurl = "http://$hostname:$port/api/setLastPlayed?song=$url&time=$lastPlayed";
		my $http = LWP::UserAgent->new;
		$http->timeout($prefs->get('musicip_timeout'));
		my $response = $http->get($musicipurl);
		if ($response->is_success) {
			my $result = $response->content;
			chomp $result;

			if ($result && $result > 0) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Set LastPlayed = $lastPlayed for $url");
			} else {
				$log->warn("Failure setting LastPlayed = $lastPlayed for $url");
				$errors++;
			}
		} else {
			$log->warn("Failed to call MusicIP at: $musicipurl");
			$errors++;
		}
	}
}

sub getMusicIpURL {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('url = '.Data::Dump::dump($url));

	my $replacePath = $prefs->get('musicip_mipmusicpath');
	if ($replacePath) {
		$replacePath =~ s/\\/\//isg;
		$replacePath = escape($replacePath);
		my $nativeRoot = $prefs->get('musicip_lmsmusicpath');
		if (!defined($nativeRoot) || $nativeRoot eq '') {
			my $c = $serverPrefs->get('audiodir');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('nativeRoot url = '.Data::Dump::dump($nativeRoot));

		my $nativeUrl = Slim::Utils::Misc::fileURLFromPath($nativeRoot);
		main::DEBUGLOG && $log->is_debug && $log->debug('nativeRoot url = '.Data::Dump::dump($nativeUrl));
		if ($url =~ /$nativeUrl/) {
			$url =~ s/\\/\//isg;
			$nativeUrl =~ s/\\/\//isg;
			$url =~ s/$nativeUrl/$replacePath/isg;
			main::DEBUGLOG && $log->is_debug && $log->debug('nativeRoot url = '.Data::Dump::dump($nativeUrl));
		} else {
			$url = Slim::Utils::Misc::pathFromFileURL($url);
			main::DEBUGLOG && $log->is_debug && $log->debug('path = '.Data::Dump::dump($url));
		}
	} else {
		$url = Slim::Utils::Misc::pathFromFileURL($url);
		main::DEBUGLOG && $log->is_debug && $log->debug('path = '.Data::Dump::dump($url));
	}

	my $replaceExtension = $prefs->get('musicip_replaceextension');
	if ($replaceExtension) {
		$replaceExtension = '.'.$replaceExtension unless substr($replaceExtension, 0, 1) eq '.';
		$url =~ s/\.[^.]*$/$replaceExtension/isg;
		main::DEBUGLOG && $log->is_debug && $log->debug('url = '.Data::Dump::dump($url));
	}
	$url =~ s/\\/\//isg;
	main::DEBUGLOG && $log->is_debug && $log->debug('url after regex = '.Data::Dump::dump($url));
	$url = unescape($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('url after unescape = '.Data::Dump::dump($url));
	$url = URI::Escape::uri_escape($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('url after escape = '.Data::Dump::dump($url));
	return $url;
}

sub finishExport {
	my $hostname = $prefs->get('musicip_hostname');
	my $port = $prefs->get('musicip_port');
	my $musicipurl = "http://$hostname:$port/api/cacheid";
	main::DEBUGLOG && $log->is_debug && $log->debug("Calling: $musicipurl");
	my $http = LWP::UserAgent->new;
	$http->timeout($prefs->get('musicip_timeout'));
	my $response = $http->get("http://$hostname:$port/api/flush");
	if (!$response->is_success) {
		$log->warn('Failed to flush MusicIP cache');
		$errors++;
	}
	$http = LWP::UserAgent->new;
	$http->timeout($prefs->get('musicip_timeout'));
	$response = $http->get($musicipurl);
	if ($response->is_success) {
		my $modificationTime = $response->content;
		chomp $modificationTime;
		$lastMusicIpDate = $modificationTime;
	} else {
		$log->warn("Failed to call MusicIP at: $musicipurl");
		$errors++;
	}
}

sub exportScheduler {
	main::DEBUGLOG && $log->is_debug && $log->debug('Checking export scheduler');
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing all export timers');
	Slim::Utils::Timers::killTimers(undef, \&exportScheduler);

	if ($prefs->get('scheduledexports')) {
		if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
			main::INFOLOG && $log->is_info && $log->info('Detected active LMS scan. Will try again in 30 minutes.');
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1800, \&exportScheduler);
			return;
		}
		my $exporttime = $prefs->get('exporttime');
		my $day = $prefs->get('export_lastday');
		if (!defined($day)) {
			$day = '';
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('export time = '.Data::Dump::dump($exporttime));
		main::DEBUGLOG && $log->is_debug && $log->debug('last export day = '.Data::Dump::dump($day));

		if (defined($exporttime) && $exporttime ne '') {
			my $time = 0;
			$exporttime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;
			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
			main::DEBUGLOG && $log->is_debug && $log->debug('local time = '.Data::Dump::dump(padnum($hour).':'.padnum($min).':'.padnum($sec).' -- '.padnum($mday).'.'.padnum($mon).'.'));

			my $currenttime = $hour * 60 * 60 + $min * 60;

			if (($day ne $mday) && $currenttime > $time) {
				main::INFOLOG && $log->is_info && $log->info('Starting scheduled export');
				eval {
					Slim::Utils::Scheduler::add_task(\&initExport);
				};
				if ($@) {
					$log->error("Scheduled export failed: $@");
				}
				$prefs->set('export_lastday',$mday);
			} else {
				my $timeleft = $time - $currenttime;
				if ($day eq $mday) {
					$timeleft = $timeleft + 60 * 60 * 24;
				}
				main::DEBUGLOG && $log->is_debug && $log->debug(parse_duration($timeleft)." ($timeleft seconds) left until next scheduled export time. The actual export happens no later than 30 minutes after the set export time.");
			}

			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1800, \&exportScheduler);
		}
	}
}

sub _setPostScanCBTimer {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for post-scan export to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&delayedPostScanExport);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed post-scan export');
	Slim::Utils::Timers::setTimer(undef, time() + 10, \&delayedPostScanExport);
}

sub delayedPostScanExport {
	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Scan in progress. Waiting for current scan to finish.');
		_setPostScanCBTimer();
	} else {
		main::INFOLOG && $log->is_info && $log->info('Will start post-scan export now');
		eval {
			Slim::Utils::Scheduler::add_task(\&initExport);
		};
		if ($@) {
			$log->error("Post-scan export failed: $@");
		}
	}
}


sub isTimeOrEmpty {
	my ($name, $arg) = @_;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub padnum {
	use integer;
	sprintf("%02d", $_[0]);
}

sub convertRating {
	my $rating100ScaleValue = shift;
	if (!$rating100ScaleValue || $rating100ScaleValue < 10) {
		return 0;
	} elsif ($rating100ScaleValue < 30) {
		return 1; # 10 - 29
	} elsif ($rating100ScaleValue < 50) {
		return 2; # 30 - 49
	} elsif ($rating100ScaleValue < 70) {
		return 3; # 50 - 69
	} elsif ($rating100ScaleValue < 90) {
		return 4; # 70 - 89
	} else {
		return 5; # > 90
	}
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
