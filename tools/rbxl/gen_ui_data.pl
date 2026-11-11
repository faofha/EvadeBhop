#!/usr/bin/perl
# Build the EVADE_UI Lua table from rbxl_reader exports.
use strict; use warnings;
my $dir = shift;
sub rows {
    my ($file, $keep) = @_;
    open my $f, "<", "$dir/$file" or die "$file: $!";
    my @out;
    while (my $l = <$f>) {
        next unless $l =~ /^\s*\{ Path = "([^"]*)"/;
        my $p = $1;
        next if $keep && !$keep->($p);
        $l =~ s/, Sink=\d+//g; $l =~ s/Sink=\d+, //g;
        $l =~ s/BorderColor3=Color3\.new\([^)]*\), //g; $l =~ s/, BorderColor3=Color3\.new\([^)]*\)//g;
        $l =~ s/Props = \{  \}/Props = {}/;
        $l =~ s/^\s*/\t\t/;
        push @out, $l;
    }
    return join("", @out);
}
my $mobileKeep = sub {
    my $p = shift;
    return 1 if $p =~ m{^Mobile(/Left|/Right)?(/Mobile)?$};
    return 1 if $p =~ m{^Mobile/Left/UI};
    return 1 if $p =~ m{^Mobile/(Left/Mobile/(ChangePovButton|MenuButton)|Right/Mobile/(CrouchButton|EmoteButton))(/|$)};
    return 0;
};
print "-- Generated from Evade's place file with tools/rbxl/rbxl_reader.luau (export). Do not edit by hand.\n";
print "local EVADE_UI = {\n";
for ([ "SettingsView", "exp_view_settings.luau" ], [ "Slider", "exp_slider.luau" ], [ "Boolean", "exp_boolean.luau" ],
     [ "TopButton", "exp_topbutton.luau" ], [ "TopExit", "exp_topexit.luau" ]) {
    print "\t$_->[0] = {\n", rows($_->[1]), "\t},\n";
}
print "\tMobile = {\n", rows("exp_mobile.luau", $mobileKeep), "\t},\n";
# Emote wheel (HUD/Interactors/Popups/Emote); the slot ViewportFrames are left out.
print "\tEmoteWheel = {\n", rows("exp_emote_wheel.luau", sub { return $_[0] !~ m{/ViewportFrame} }), "\t},\n";
print "}\n";
