use Data::Dump;
use Mojo::URL;
use Scalar::Util qw/looks_like_number/;
use Tie::YAML;

tie my %goathashes => 'Tie::YAML', 'goathashes.yaml';

my %r;
while (my ($key, $val) = each %goathashes) {
	if (!exists $r{$val}) {
		$r{$val} = [ $key ];
	}
	else {
		push @{ $r{$val} }, $key;
	}
}

my $base = Mojo::URL->new("http://www.goatbots.com");

while (my ($val, $keys) = each %r) {
	if (@{ $keys } != 1 || grep { $val eq $_ } @ARGV) {
		for my $hash (@{ $keys }) {
			my $price;
			do {
				my $url = $base->clone;
				$url->path("/assets/images/prices/hashes/${hash}.png");
				print $url . " ";
				chomp($price = <STDIN>);
			} while (!looks_like_number $price);

			$goathashes{$hash} = $price;
		}
	}
}

tied(%goathashes)->save;
