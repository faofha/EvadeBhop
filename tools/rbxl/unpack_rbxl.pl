#!/usr/bin/perl
# Decompress every chunk of a binary .rbxl using Windows tar (libarchive + libzstd).
# Each zstd chunk becomes a tar entry: [raw zstd frame: tar header] [original zstd frame] [raw frame: padding].
# Usage: perl unpack_rbxl.pl in.rbxl workdir out.rbxl
use strict; use warnings;
my ($in, $work, $out) = @ARGV;
open my $f, "<:raw", $in or die "open $in: $!"; local $/; my $d = <$f>; close $f;

sub raw_frame { # zstd frame made of raw (stored) blocks
    my ($data) = @_;
    my $s = "\x28\xb5\x2f\xfd" . chr(0xA0) . pack("V", length $data); # single segment, 4-byte FCS
    my $len = length $data; my $off = 0;
    if ($len == 0) { return $s . pack("V", 1) & "\xff\xff\xff" ; }
    while ($off < $len) {
        my $n = $len - $off; $n = 65536 if $n > 65536;
        my $last = ($off + $n >= $len) ? 1 : 0;
        my $hdr = ($n << 3) | (0 << 1) | $last;
        $s .= substr(pack("V", $hdr), 0, 3) . substr($data, $off, $n);
        $off += $n;
    }
    return $s;
}
sub tar_header {
    my ($name, $size) = @_;
    my $h = pack("a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 a12",
        $name, "0000644", "0000000", "0000000", sprintf("%011o", $size), sprintf("%011o", 0),
        "        ", "0", "", "ustar", "00", "", "", "", "", "", "");
    my $sum = 0; $sum += ord($_) for split //, $h;
    substr($h, 148, 8) = sprintf("%06o", $sum) . "\0 ";
    return $h;
}
sub lz4_block {
    my ($src, $outlen) = @_;
    my $dst = ""; my $s = 0; my $L = length $src;
    while ($s < $L) {
        my $tok = ord substr($src, $s++, 1); my $lit = $tok >> 4;
        if ($lit == 15) { my $b; do { $b = ord substr($src, $s++, 1); $lit += $b } while ($b == 255) }
        $dst .= substr($src, $s, $lit); $s += $lit;
        last if $s >= $L;
        my $off = unpack("v", substr($src, $s, 2)); $s += 2;
        my $ml = $tok & 15;
        if ($ml == 15) { my $b; do { $b = ord substr($src, $s++, 1); $ml += $b } while ($b == 255) }
        $ml += 4;
        my $start = length($dst) - $off;
        for (my $i = 0; $i < $ml; $i++) { $dst .= substr($dst, $start + $i, 1) }
    }
    return $dst;
}

my @chunks; my $p = 32;
my $stream = "";
while ($p < length $d) {
    my ($n, $cl, $ul) = unpack("a4 V V", substr($d, $p, 12)); $p += 16;
    my $body; my $kind;
    if ($cl == 0) { $body = substr($d, $p, $ul); $p += $ul; $kind = "raw"; }
    else {
        my $raw = substr($d, $p, $cl); $p += $cl;
        if (substr($raw, 0, 4) eq "\x28\xb5\x2f\xfd") {
            my $i = scalar @chunks;
            my $name = sprintf("c%05d", $i);
            $stream .= raw_frame(tar_header($name, $ul)) . $raw;
            my $pad = (512 - ($ul % 512)) % 512;
            $stream .= raw_frame("\0" x $pad) if $pad;
            $kind = "zstd";
        } else { $body = lz4_block($raw, $ul); $kind = "lz4"; }
    }
    push @chunks, { name => $n, ul => $ul, kind => $kind, body => $body };
    last if $n eq "END\0";
}
$stream .= raw_frame("\0" x 1024);
mkdir $work;
open my $t, ">:raw", "$work/all.tar.zst" or die; print $t $stream; close $t;
my $rc = system("/c/Windows/System32/tar.exe", "-xf", "$work/all.tar.zst", "-C", $work);
die "tar failed: $rc" if $rc;

open my $o, ">:raw", $out or die; print $o substr($d, 0, 32);
my %count;
for my $i (0 .. $#chunks) {
    my $c = $chunks[$i]; my $body = $c->{body};
    if ($c->{kind} eq "zstd") {
        open my $cf, "<:raw", sprintf("%s/c%05d", $work, $i) or die "missing chunk $i"; $body = <$cf>; close $cf;
    }
    die "size mismatch chunk $i" if length($body) != $c->{ul};
    print $o $c->{name} . pack("V V V", 0, length $body, 0) . $body;
    $count{$c->{kind}}++;
}
close $o;
print join(" ", map { "$_=$count{$_}" } sort keys %count), " total=", scalar(@chunks), "\n";
