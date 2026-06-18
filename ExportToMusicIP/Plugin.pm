#
# Export To MusicIP
# (c) 2024 AF
# Licensed under the GPLv3 - see LICENSE file
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
use Slim::Schema;

my $apc_enabled = 0;
my $lastMusicIpDate = 0;
my $MusicIpExportStartTime = 0;
my $exportAborted = 0;
my $errors = 0;
my $mip_hostname = '';
my $mip_port = 0;
my $mip_timeout = 15;
my @songs = ();

my $prefs = preferences('plugin.exporttomusicip');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.exporttomusicip',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_EXPORTTOMUSICIP',
});

sub initPlugin {
	my $class = shift;
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
		Slim::Utils::Timers::setTimer(undef, time() + 2, \&exportScheduler);
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
		mip_rating_threshold => 0,
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
	$mip_hostname = $prefs->get('musicip_hostname');
	$mip_port = $prefs->get('musicip_port');
	$mip_timeout = $prefs->get('musicip_timeout');
	$http->timeout($mip_timeout);
	my $musiciptesturl = "http://$mip_hostname:$mip_port/api/cacheid";
	my $response = $http->get($musiciptesturl);
	if (!$response->is_success) {
		$log->error("Failed to call MusicIP at: $musiciptesturl. Please check if the MusicIP hostname/ip address and port in the plugin settings are correct and confirm that the MusicIP service is running and can be accessed via URL from this computer.");
		$errors++;
	}

	unless ($errors) {
		my $table = ($apc_enabled && $prefs->get('useapcvalues')) ? 'alternativeplaycount' : 'tracks_persistent';
		my $sql = "SELECT tracks_persistent.url, $table.playCount, $table.lastPlayed, tracks_persistent.rating FROM tracks_persistent,tracks";
		$sql .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled && $prefs->get('useapcvalues'));
		my $whereLastPlayed = ($apc_enabled && $prefs->get('useapcvalues')) ? "$table.lastPlayed" : 'tracks_persistent.lastPlayed';
		$sql .= " where tracks_persistent.urlmd5 = tracks.urlmd5 and ifnull(tracks.remote,0) = 0 and ($whereLastPlayed is not null or tracks_persistent.rating > 0)";

		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare($sql);
		my ($url, $playCount, $lastPlayed, $rating);
		eval {
			$sth->execute();
			$sth->bind_columns(undef, \$url, \$playCount, \$lastPlayed, \$rating);
			while( $sth->fetch() ) {
				my $thisTrack = {
					'url' => $url,
					'rating' => ($rating ? mapRatingToMip($rating) : 0),
					'playcount' => $playCount,
					'lastplayed' => $lastPlayed,
				};
				push @songs, $thisTrack;
			}
			$sth->finish();
		};
		if ($@) {
			$log->warn("SQL error: $@");
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

		finishExport() unless $exportAborted;
	}

	# export result: 1 = success, 2 = aborted, 3 = errors
	if ($exportAborted) {
		$prefs->set('exportResult', 2);
		main::INFOLOG && $log->is_info && $log->info('Export aborted after '.(time() - $MusicIpExportStartTime).' seconds.');
	} elsif ($errors > 0) {
		$prefs->set('exportResult', 3);
		main::INFOLOG && $log->is_info && $log->info('Export failed or completed with errors after '.(time() - $MusicIpExportStartTime).' seconds.');
	} else {
		$prefs->set('exportResult', 1);
		main::INFOLOG && $log->is_info && $log->info('Export successfully completed after '.(time() - $MusicIpExportStartTime).' seconds.');
		$prefs->set('lastMusicIpDate', $lastMusicIpDate);
	}

	$prefs->set('ExportInProgress', 0);
	Slim::Utils::Timers::setTimer(undef, time() + 20, sub {$prefs->set('exportResult', 0);});
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
	main::DEBUGLOG && $log->is_debug && $log->debug('track url = ' . Data::Dump::dump($url));
	my $rating = $track->{'rating'};
	main::DEBUGLOG && $log->is_debug && $log->debug('track rating = ' . Data::Dump::dump($rating));
	my $playCount = $track->{'playcount'};
	main::DEBUGLOG && $log->is_debug && $log->debug('track playCount = ' . Data::Dump::dump($playCount));
	my $lastPlayed = $track->{'lastplayed'};
	main::DEBUGLOG && $log->is_debug && $log->debug('lastPlayed = ' . Data::Dump::dump($lastPlayed));

	if (!$url) {
		$log->warn('No url for track');
		$errors++;
		return;
	}

	$url = getMusicIpURL($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('musicip url = ' . Data::Dump::dump($url));

	my $http = LWP::UserAgent->new;
	$http->timeout($mip_timeout);

	if ($rating && $rating > 0) {
		my $response = $http->get("http://$mip_hostname:$mip_port/api/setRating?song=$url&rating=$rating");
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
			$log->warn("Failed to call MusicIP: setRating for $url");
			$errors++;
		}
	}
	if ($playCount) {
		my $response = $http->get("http://$mip_hostname:$mip_port/api/setPlayCount?song=$url&count=$playCount");
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
			$log->warn("Failed to call MusicIP: setPlayCount for $url");
			$errors++;
		}
	}
	if ($lastPlayed) {
		my $response = $http->get("http://$mip_hostname:$mip_port/api/setLastPlayed?song=$url&time=$lastPlayed");
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
			$log->warn("Failed to call MusicIP: setLastPlayed for $url");
			$errors++;
		}
	}
}

sub getMusicIpURL {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('url = '.Data::Dump::dump($url));

	my $replacePath = $prefs->get('musicip_mipmusicpath');
	if ($replacePath) {
		$replacePath =~ s/\\/\//g;
		$replacePath = escape($replacePath);
		my $nativeRoot = $prefs->get('musicip_lmsmusicpath');
		if (!defined($nativeRoot) || $nativeRoot eq '') {
			$nativeRoot = $serverPrefs->get('audiodir');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('nativeRoot = '.Data::Dump::dump($nativeRoot));

		my $nativeUrl = Slim::Utils::Misc::fileURLFromPath($nativeRoot);
		main::DEBUGLOG && $log->is_debug && $log->debug('nativeUrl = '.Data::Dump::dump($nativeUrl));
		if ($url =~ /\Q$nativeUrl\E/) {
			$url =~ s/\\/\//g;
			$nativeUrl =~ s/\\/\//g;
			$url =~ s/\Q$nativeUrl\E/$replacePath/;
			main::DEBUGLOG && $log->is_debug && $log->debug('url after path substitution = '.Data::Dump::dump($url));
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
		$url =~ s/\.[^.]*$/$replaceExtension/;
		main::DEBUGLOG && $log->is_debug && $log->debug('url = '.Data::Dump::dump($url));
	}
	$url =~ s/\\/\//g;
	main::DEBUGLOG && $log->is_debug && $log->debug('url after regex = '.Data::Dump::dump($url));
	$url = unescape($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('url after unescape = '.Data::Dump::dump($url));
	$url = URI::Escape::uri_escape($url);
	main::DEBUGLOG && $log->is_debug && $log->debug('url after escape = '.Data::Dump::dump($url));
	return $url;
}

sub finishExport {
	my $musicipurl = "http://$mip_hostname:$mip_port/api/cacheid";
	main::DEBUGLOG && $log->is_debug && $log->debug("Calling: $musicipurl");
	my $http = LWP::UserAgent->new;
	$http->timeout($mip_timeout);
	my $response = $http->get("http://$mip_hostname:$mip_port/api/flush");
	if (!$response->is_success) {
		$log->warn('Failed to flush MusicIP cache');
		$errors++;
	}
	$response = $http->get($musicipurl);
	if ($response->is_success) {
		$lastMusicIpDate = $response->content;
		chomp $lastMusicIpDate;
	} else {
		$log->warn("Failed to call MusicIP at: $musicipurl");
		$errors++;
	}
}

sub exportScheduler {
	main::DEBUGLOG && $log->is_debug && $log->debug('Checking export scheduler');
	Slim::Utils::Timers::killTimers(undef, \&exportScheduler);

	return unless $prefs->get('scheduledexports');

	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		main::INFOLOG && $log->is_info && $log->info('Detected active LMS scan. Will try again in 30 minutes.');
		Slim::Utils::Timers::setTimer(undef, time() + 1800, \&exportScheduler);
		return;
	}

	if ($prefs->get('ExportInProgress')) {
		main::INFOLOG && $log->is_info && $log->info('Export already in progress. Scheduler will retry in 30 minutes.');
		Slim::Utils::Timers::setTimer(undef, time() + 1800, \&exportScheduler);
		return;
	}

	my $exporttime = $prefs->get('exporttime');
	my $day = $prefs->get('export_lastday') // '';
	main::DEBUGLOG && $log->is_debug && $log->debug('export time = ' . Data::Dump::dump($exporttime));
	main::DEBUGLOG && $log->is_debug && $log->debug('last export day = ' . Data::Dump::dump($day));

	if (defined($exporttime) && $exporttime ne '') {
		my $time = 0;
		if ($exporttime =~ m{^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$}i) {
			if (defined $3) {
				$time = ($1 == 12 ? 0 : $1 * 3600) + ($2 * 60) + ($3 =~ /P/i ? 43200 : 0);
			} else {
				$time = ($1 * 3600) + ($2 * 60);
			}
		} else {
			main::INFOLOG && $log->is_info && $log->info("Invalid export time value: '$exporttime'. Skipping scheduled export.");
			Slim::Utils::Timers::setTimer(undef, time() + 1800, \&exportScheduler);
			return;
		}
		my ($sec, $min, $hour, $mday) = (localtime(time()))[0, 1, 2, 3];
		main::DEBUGLOG && $log->is_debug && $log->debug('local time = ' . Data::Dump::dump(padnum($hour) . ':' . padnum($min) . ':' . padnum($sec) . ' -- ' . padnum($mday) . '.'));

		my $currenttime = $hour * 60 * 60 + $min * 60;

		if (($day != $mday) && $currenttime > $time) {
			main::INFOLOG && $log->is_info && $log->info('Starting scheduled export');
			eval {
				Slim::Utils::Scheduler::add_task(\&initExport);
			};
			if ($@) {
				$log->error("Scheduled export failed: $@");
			}
			$prefs->set('export_lastday', $mday);
		} else {
			my $timeleft = $time - $currenttime;
			if ($day == $mday) {
				$timeleft = $timeleft + 60 * 60 * 24;
			}
			main::DEBUGLOG && $log->is_debug && $log->debug(parse_duration($timeleft) . " ($timeleft seconds) left until next scheduled export time. The actual export happens no later than 30 minutes after the set export time.");
		}

		Slim::Utils::Timers::setTimer(undef, time() + 1800, \&exportScheduler);
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
	} elsif ($arg =~ m/^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])(P|PM|A|AM)?$/i) {
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

sub mapRatingToMip {
	my $lmsRating = shift;
	my $threshold = $prefs->get('mip_rating_threshold') || 0;

	return convertRating($lmsRating) unless $threshold > 0 && $threshold < 5;

	# values below threshold*20 (exclusive) export as 0; threshold*20 and above are stretched onto MIP 1-5
	return 0 if !$lmsRating || $lmsRating < ($threshold * 20);
	my $lmsMin = $threshold * 20;
	my $lmsRange = 100 - $lmsMin;
	return int(($lmsRating - $lmsMin) / $lmsRange * 5 + 0.5) || 1;
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
