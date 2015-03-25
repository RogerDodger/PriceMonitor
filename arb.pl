#!/usr/bin/env perl
use 5.01;
use strict;
use warnings;

BEGIN {
	use FindBin qw/$Bin/;
	chdir $Bin;
}

use lib '../MojoMafia/lib';

use DBI;
use Mafia::Timestamp;
use Mojo::IOLoop;
use Term::ANSIScreen qw/:cursor :screen :color/;

my $dbh = do {
	my $fn = 'prices.db';
	my $exists = -e $fn;
	my $dbh = DBI->connect("dbi:SQLite:$fn","","", { sqlite_unicode => 1 });

	# Load schema if DB didn't already exist
	if (!$exists) {
		open my $fh, '<', 'schema.sql';
		local $/ = ';';
		while (my $stmt = readline $fh) {
			$dbh->do($stmt);
		}
		close $fh;
	}

	$dbh;
};

# Cleanup old prices
Mojo::IOLoop->recurring(10 => sub {
	state $stmt = $dbh->prepare('DELETE FROM prices WHERE ts < ?');
	$stmt->execute(time - 60 * 60);
});

my $t0 = Mafia::Timestamp->now;

# Output loop
Mojo::IOLoop->recurring(3 => sub {
	state $hfmt = "%-3s %-16s  %-12s %-7s %-12s %-7s %-6s %7s  \n";
	state $rfmt = "%-3s %-16s  %-12s %5.2f   %-12s %5.2f    %5.2f %6.2f%%  \n";
	state $hdr = sprintf $hfmt, qw/Set Card Buyer Price Seller Price Profit ROI/;
	state $stmt = $dbh->prepare(q{
		SELECT * FROM diffs
		WHERE 'mtgPlayersBot' != buyer
		--WHERE roi < 15 OR profit < .20
		--WHERE card NOT IN ('Master of Waves', 'Thassa, God of the Sea'
		LIMIT 18
	});

	$stmt->execute;
	my $buf;
	while (my $row = $stmt->fetchrow_hashref) {
		$buf .= sprintf $rfmt,
			$row->{setname},
			substr($row->{card}, 0, 16),
			substr($row->{buyer}, 0, 12),
			$row->{buyprice},
			substr($row->{seller}, 0, 12),
			$row->{sellprice},
			$row->{profit},
			$row->{roi};
	}

	if ($buf) {
		cls;
		say "PriceMonitor";
		say "uptime: " . substr($t0->delta, 0, -4);
		say q{};

		print colored ($hdr, 'black on_white');
		print colored ('', 'reset');
		print $buf;
		print "\n";
	}
});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
