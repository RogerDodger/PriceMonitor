#!/usr/bin/env perl
use 5.01;
use strict;
use warnings;

BEGIN {
	use FindBin qw/$Bin/;
	chdir $Bin;
}

use Data::Dump;
use DBI;
use Mojo::IOLoop;
use Mojo::Loader qw/data_section/;
use Mojo::JSON qw/decode_json/;
use Mojo::UserAgent;
use Time::HiRes qw/gettimeofday tv_interval/;
use Tie::YAML;
use Scalar::Util qw/looks_like_number/;

sub BUY () { 0 }
sub SELL () { 1 }
sub SELL_MIN () { 0.5 }
sub BUY_MIN () { 0.3 }

sub trim {
	local $_ = shift;
	s/^\s+|\s+$//g;
	s/\s+/ /g;
	$_;
}

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

my $ua = Mojo::UserAgent->new;

# Continuously change the UserAgent to a common one
my @agents = split $/, data_section __PACKAGE__, 'user-agents.txt';
my $spoof = sub { $ua->transactor->name($agents[rand @agents]); };
$spoof->();
Mojo::IOLoop->recurring(1 => $spoof);

tie my %goathashes => 'Tie::YAML', 'goathashes.yaml';

my @standard = qw/frf ktk jou bng ths m15/;
my @shops = (
	(map _cardhoarder($_), 1, 2),
	(map _clanteam($_), @standard),
	(map _dojotradebots($_), @standard),
	#(map _goatbots($_), @standard),
	(map _mtgoempire(), undef),
	(map _mtgplayersbot($_), qw/ktk frf/),
	(map _supernovabots(), undef),
	(map _thecardnexus(), undef),
);

Mojo::IOLoop->delay( map {
	my $shop = $_;
	my $fetch = sub {
		my $t0 = [gettimeofday];

		$ua->get($shop->{url}, sub {
			my ($ua, $tx) = @_;

			if (!$tx->success) {
				debug("$shop->{name} fetch failed: " . $tx->error->{message});
				return;
			}

			my $cards = $shop->{parse}->(@_);
			for my $card (@$cards) {
				my ($buy, $sell) = @{$card}{qw/buy sell/};

				next if small_fry($buy, $sell);
				my $card_id = find_card(@{$card}{qw/name setname isfoil/});

				update_price($card_id, $shop->{name}, BUY, $buy);
				update_price($card_id, $shop->{name}, SELL, $sell);
			}

			debug(
				"%s prices updated (%.2fs)",
				$shop->{name} . (exists $shop->{subname} ? " $shop->{subname}" : ''),
				tv_interval($t0, [gettimeofday]),
			);
		});
	};
	sub {
		my $delay = shift;
		Mojo::IOLoop->timer(5 => $delay->begin);
		$fetch->();
		Mojo::IOLoop->recurring(120 => $fetch);
	}
} @shops )->wait;

sub _cardhoarder {
	my $page = shift;

	my $url = Mojo::URL->new("https://www.cardhoarder.com");
	$url->path("/cards/index/sort:color-name/viewtype:list/page:$page");
	$url->query(
		"data[in_stock_only]=1&" .
		"data[sell][range][gte]=" . SELL_MIN . "&" .
		"data[sets][0]=KTK&data[sets][1]=FRF&" .
		"data[sets][2]=M15&data[sets][3]=THS&" .
		"data[sets][4]=BNG&data[sets][5]=JOU"
	);

	return {
		name => 'Cardhoarder',
		subname => "p$page",
		url => $url,
		parse => sub {
			my ($ua, $tx) = @_;

			my @cards;
			if (my $table = $tx->res->dom->at('#search-results-list')) {
				for my $row ($table->find('tr')->each) {
					my $cols = $row->find('td');
					next unless $cols->size == 7;

					my %card;
					$card{name} = trim $cols->[0]->at('a')->text;
					next if $card{name} =~ /Booster/;
					$card{isfoil} = 0;
					$card{setname} = trim $cols->[2]->text;
					$card{sell} = trim $cols->[5]->text;
					push @cards, \%card;
				}
			}
			return \@cards;
		},
	};
}

sub _clanteam {
	my $set = uc shift;

	return {
		name => 'ClanTeam',
		subname => $set,
		url => "mtgoclanteam.com/Cards?edition=$set",
		parse => sub {
			my ($ua, $tx) = @_;

			my $js = $tx->res->dom->at('#templatemo_content')->at('script')->text;
			$js =~ m{( \{ .+ \} )}xs;

			my @cards;
			for my $row (@{ decode_json($1)->{aaData} }) {
				my %card;
				$card{name} = $row->[0];
				$card{setname} = $set;
				$card{isfoil} = 0;
				$card{buy} = $row->[2] if looks_like_number $row->[2];
				$card{sell} = $row->[3] if looks_like_number $row->[3];
				push @cards, \%card;
			}

			return \@cards;
		}
	}
}

sub _dojotradebots {
	my $set = uc shift;

	return {
		name => 'DojoTrade Bots',
		subname => $set,
		url => "www.dojotradebots.com/assets/pricedata.php?s=$set",
		parse => sub {
			my ($ua, $tx) = @_;

			my @cards;
			for my $row (@{ $tx->res->json->{aaData} }) {
				my %card;
				$card{name} = $row->[1] =~ s{<a.+>([^<>]+)</a>}{$1}r;
				next if $card{name} =~ /Booster/;

				$card{isfoil} = 0;
				$card{setname} = $set;
				$card{sell} = $row->[3] if looks_like_number $row->[3];
				$card{buy} = $row->[4] if looks_like_number $row->[4];
				return unless length trim $row->[5];
				push @cards, \%card if !small_fry(\%card);
			}
			return \@cards;
		},
	};
}

sub _goatbots {
	my $set = shift;
	return {
		name => 'GoatBots',
		subname => uc $set,
		url => "http://www.goatbots.com/prices-${set}.php",
		parse => sub {
			my ($ua, $tx) = @_;

			# These guys actually try to obfuscate the prices from bots in
			# multiple rather stranger (that is, ineffective) ways.

			# First, the prices are all images, indexed by some hash of the
			# price. We can work around this by manually inputting the value
			# associated with each hash.

			# More strangely, the images in the original table are actually in
			# some cases fake! The real prices are stored in a separate part
			# of the document and then inserted over the fake prices with
			# JavaScript. This first pass does that for us too.
			my $dom = $tx->res->dom;

			# They removed this from their page, after realising how easy
			# it is to bypass. ^^

			# my @prices = split m{\\}, $dom->at('#orderPricing')->content;
			# my $rows = $dom->find('tr');
			# while (@prices) {
			# 	my $row = int shift @prices;
			# 	my $col = int shift @prices;
			# 	my $src = substr shift @prices, 10, 64;
			# 	$rows->[$row]->find('td')->[$col]->at('img')->attr(src => $src);
			# }

			my @cards;
			CARD: for my $e ($dom->at('#pricesTable')->find('tr')->each) {
				my $cols = $e->find('td');
				next if $cols->size != 5;
				next if $cols->[1]->text !~ /[CURM]/;

				my %card;
				$card{name} = trim $cols->[0]->text;
				$card{setname} = uc $set;
				$card{isfoil} = 0;

				my @type = qw/buy sell/;
				PRICE: for my $e ($e->find('img')->each) {
					next PRICE unless $e->attr('src') =~ m{/([0-9a-f]{32})\.png$};
					my ($hash, $key) = ($1, shift @type);

					if (!exists $goathashes{$hash}) {
						my $url = $tx->req->url->clone;
						$url->path($e->attr('src'));

						my $price = tesseract($url);
						next PRICE if !defined $price;

						$price /= 100;

						$goathashes{$hash} = $price;
						tied(%goathashes)->save;
					}

					my $price = $goathashes{$hash};
					next if $price < 0;

					$card{$key} = $price;
					last CARD if $key eq 'buy'  && $price < BUY_MIN;
					last CARD if $key eq 'sell' && $price < SELL_MIN;
				}

				push @cards, \%card;
			}

			return \@cards;
		},
	};
}

sub _mtgoempire {
	return {
		name => 'MTGO Empire',
		url => 'http://mtgoempire.com/MOD_INV.html',
		parse => sub {
			my ($ua, $tx) = @_;
			my $info = $tx->res->dom->at('pre')->text;

			my @cards;
			for my $line (split $/, $info) {
				next if length $line < 80;

				# The 49th char is a rarity indicator, always upper case;
				# use it to check if the line is a row of data or not
				next if substr($line, 49, 1) !~ /[A-Z]/;

				my %card;
				$card{name}    = substr($line, 5, 42) =~ s/\s+$//r;
				$card{setname} = substr $line, 0, 3;
				$card{isfoil}  = 0;

				my $buy = substr($line, 55, 9);
				my $sell = substr($line, 71, 9);

				$card{buy} = $buy + 0 if looks_like_number $buy;
				$card{sell} = $sell + 0 if looks_like_number $sell;

				push @cards, \%card if !small_fry(\%card);
			}

			return \@cards;
		},
	};
}

sub _mtgplayersbot {
	my $set = uc shift;
	return {
		name => 'mtgPlayersBot',
		subname => $set,
		url => "http://www.mtgplayersbot.com/WebSite/${set}.aspx",
		parse => sub {
			my ($ua, $tx) = @_;

			my @cards;
			for my $e ($tx->res->dom->at('#GridView1')->find('tr')->each) {
				my $cols = $e->find('td');
				next unless $cols->size == 5;

				my %card;
				$card{name} = $cols->[0]->text;
				$card{setname} = $set;
				$card{isfoil} = 0;
				$card{buy} = $cols->[1]->text;
				if ($cols->[3]->text + $cols->[4]->text > 0) {
					$card{sell} = $cols->[2]->text;
				}
				else {
					# Some inordinate amount
					$card{sell} = 999;
				}
				push @cards, \%card if !small_fry(\%card);
			}

			return \@cards;
		},
	};
}

sub _supernovabots {
	return {
		name => 'SupernovaBots',
		url => 'http://www.supernovabots.com/prices_0.txt',
		parse => sub {
			my ($ua, $tx) = @_;

			my @cards;
			for my $line (split $/, $tx->res->body) {
				my $id = substr $line, 0, 41;
				next if $id !~ m{ ^ (.+) \s \[ (.{3}) \] }x;

				my %card;
				$card{name} = $1;
				$card{setname} = $2;
				$card{isfoil} = 0;

				my $buy = substr $line, 42, 9;
				my $sell = substr $line, 52, 9;

				$card{buy} = $buy + 0 if looks_like_number $buy;
				$card{sell} = $sell + 0 if looks_like_number $sell;

				push @cards, \%card if !small_fry(\%card);
			}
			return \@cards;
		},
	};
}

sub _thecardnexus {
	return {
		name => 'TheCardNexus',
		url => 'http://thecardnexus.com',
		parse => sub {
			my ($ua, $tx) = @_;

			my $table = $tx->res->dom->at('table');
			return if !$table;

			my @cards;
			for my $e ($table->find('tr')->each) {
				my $cols = $e->find('td');

				next if $cols->size != 8;
				next if $cols->[1]->text eq 'B';

				my %card;
				$card{name} = $cols->[0]->at('a')->text;
				$card{setname} = $cols->[2]->text;
				$card{isfoil} = 0;
				$card{buy} = _thecardnexus_price($cols->[3]);
				$card{sell} = _thecardnexus_price($cols->[4]);
				push @cards, \%card if !small_fry(\%card);
			}
			return \@cards;
		},
	};
}

sub _thecardnexus_price {
	my $col = shift;
	my $src = $col->at('img')->attr('src');
	if ($src =~ /(\d+)$/) {
		return 0 + sprintf "%.2f", $1 * 20.002 / 4200483 - 0.012;
	}
	else {
		debug("Can't resolve price from: $src");
		return undef;
	}
}

sub debug {
	my $fmt = shift;
	printf STDERR "[%02d:%02d:%02d] %s\n", (localtime)[2,1,0], sprintf $fmt, @_;
}

sub find_card {
	my ($name, $set, $foil) = @_;

	state $select = $dbh->prepare(q{
		SELECT * FROM cards WHERE name=? AND setname=? AND foil=?
	});

	state $create = $dbh->prepare(q{
		INSERT INTO cards (name, setname, foil) VALUES (?, ?, ?)
	});

	$select->execute($name, $set, $foil);
	if (my $row = $select->fetchrow_hashref) {
		return $row->{id};
	}
	else {
		$create->execute($name, $set, $foil);
		return $dbh->last_insert_id(undef, undef, "cards", "id");
	}
}

sub small_fry {
	my ($buy, $sell) = @_;

	if (ref $buy eq 'HASH') {
		$sell = $buy->{sell};
		$buy = $buy->{buy};
	}

	if (defined $buy && defined $sell) {
		return 1 if $sell < SELL_MIN && $buy < BUY_MIN;
	}
	elsif (defined $buy) {
		return 1 if $buy < BUY_MIN;
	}
	elsif (defined $sell) {
		return 1 if $sell < SELL_MIN;
	}
	else {
		return 1;
	}
	0;
}

sub tesseract {
	state $f = "$$-ocr";
	my $url = shift;
	my $mode = shift || 'goat';

	system("wget -O $f $url");
	system("convert $f $f.jpg");
	system("tesseract $f.jpg text -psm 7");
	my $text = `cat text.txt` =~ s/\s+//gr;
	system("rm $f* text.txt");

	while (!looks_like_number $text) {
		print "OCR return ($text) not numeric. Please advise: ";
		chomp($text = <STDIN>);
		return if !length $text;
	}

	return $text + 0;
}

sub update_price {
	my ($card_id, $shop, $type, $price) = @_;
	return unless defined $price and $price != 0;

	# If $price is stringy, then DBI will insert it into the database as a
	# string, breaking all the in-DB computations
	$price += 0;

	state $select = $dbh->prepare(q{
		SELECT * FROM prices WHERE card_id=? AND shop=? AND type=?
	});
	state $update = $dbh->prepare(q{
		UPDATE prices SET price=?,ts=? WHERE card_id=? AND shop=? AND type=?
	});
	state $insert = $dbh->prepare(q{
		INSERT INTO prices (price,ts,card_id,shop,type) VALUES (?,?,?,?,?)
	});

	$select->execute($card_id, $shop, $type);
	if (my $row = $select->fetchrow_hashref) {
		return if $price == $row->{price} && $row->{ts} > time - 60 * 30;
		$update->execute($price,time,$card_id,$shop,$type);
	}
	else {
		$insert->execute($price,time,$card_id,$shop,$type);
	}
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

__DATA__

@@ user-agents.txt
Mozilla/5.0 ;Windows NT 6.1; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/36.0.1985.143 Safari/537.36
Mozilla/5.0 ;Windows NT 6.1; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/39.0.2171.95 Safari/537.36
Mozilla/5.0 ;Windows NT 6.2; WOW64; rv:27.0; Gecko/20100101 Firefox/27.0
Mozilla/5.0 ;iPhone; CPU iPhone OS 8_1_2 like Mac OS X; AppleWebKit/600.1.4 ;KHTML, like Gecko; Version/8.0 Mobile/12B440 Safari/600.1.4
Mozilla/5.0 ;Windows NT 6.1; rv:35.0; Gecko/20100101 Firefox/35.0
Mozilla/5.0 ;compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html;
Mozilla/5.0 ;Macintosh; Intel Mac OS X 10_10_2; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/40.0.2214.111 Safari/537.36
Mozilla/5.0 ;Windows NT 6.1; WOW64; rv:35.0; Gecko/20100101 Firefox/35.0
Mozilla/5.0 ;Windows NT 6.3; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/39.0.2171.95 Safari/537.36
Mozilla/5.0 ;Windows NT 6.1; rv:34.0; Gecko/20100101 Firefox/34.0
Mozilla/5.0 ;Windows NT 6.3; WOW64; Trident/7.0; rv:11.0; like Gecko
Mozilla/5.0 ;compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/7.0;
Mozilla/5.0 ;Windows NT 6.1; WOW64; rv:34.0; Gecko/20100101 Firefox/34.0
Mozilla/5.0 ;Windows NT 6.1; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/40.0.2214.111 Safari/537.36
Mozilla/5.0 ;iPhone; CPU iPhone OS 7_1_2 like Mac OS X; AppleWebKit/537.51.2 ;KHTML, like Gecko; Version/7.0 Mobile/11D257 Safari/9537.53
Mozilla/5.0 ;Windows NT 6.3; WOW64; rv:35.0; Gecko/20100101 Firefox/35.0
Mozilla/5.0 ;iPhone; CPU iPhone OS 8_1_3 like Mac OS X; AppleWebKit/600.1.4 ;KHTML, like Gecko; Version/8.0 Mobile/12B466 Safari/600.1.4
Mozilla/5.0 ;iPad; CPU OS 8_1_2 like Mac OS X; AppleWebKit/600.1.4 ;KHTML, like Gecko; Version/8.0 Mobile/12B440 Safari/600.1.4
Mozilla/5.0 ;Windows NT 6.1; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/40.0.2214.115 Safari/537.36
Mozilla/5.0 ;Windows NT 6.3; WOW64; rv:34.0; Gecko/20100101 Firefox/34.0
Mozilla/5.0 ;Windows NT 6.1; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/39.0.2171.95 Safari/537.36
Mozilla/5.0 ;Windows NT 5.1; rv:35.0; Gecko/20100101 Firefox/35.0
Mozilla/5.0 ;Windows NT 6.3; WOW64; AppleWebKit/537.36 ;KHTML, like Gecko; Chrome/40.0.2214.111 Safari/537.36
Mozilla/5.0 ;Macintosh; Intel Mac OS X 10_10_1; AppleWebKit/600.2.5 ;KHTML, like Gecko; Version/8.0.2 Safari/600.2.5
