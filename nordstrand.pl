#!/usr/bin/perl -w

use warnings;
use strict;
use Curses::UI;
use Config::Simple;
use Data::Dumper;
use DateTime;
use DateTime::Format::ISO8601;

#use Log::Log4perl qw(:easy);
#Log::Log4perl->easy_init( { level => $DEBUG,
#                           file => ">>/tmp/nordstrand.log" }
#);

#configfile laden
our $config = new Config::Simple($ENV{HOME}."/.ebaywatchrc");

our $SEEN_DB_FILE   = $config->param(-block=>'general')->{seen_db_file};
our $SEARCH_FILE   =  $config->param(-block=>'general')->{searchterms_file};
our %SEEN;

use DB_File;
use eBay::API::Simple::Finding;

#DV-File an einen Hash binden
tie %SEEN, 'DB_File', $SEEN_DB_FILE,
    O_CREAT|O_RDWR, 0755 or
    die "$!";
END { untie %SEEN }


#create Ebay API object
my $call = eBay::API::Simple::Finding->new( 
  { 
   appid =>  $config->param(-block=>'ebay-api')->{appid},
   devid => $config->param(-block=>'ebay-api')->{devid},
   certid => $config->param(-block=>'ebay-api')->{certid},
   siteid => $config->param(-block=>'ebay-api')->{siteid}
  }
);


my $cui = new Curses::UI( -color_support => 1, -mouse_support => 0 );
my @menu = ( 
  { -label => 'File', 
    -submenu => [ { -label => 'Exit ^Q', -value => \&exit_dialog  },
                  { -label => 'Fetch ^F', -value => \&fetch_ebay_data  },
                  { -label => 'Refresh ^R', -value => \&refresh_list  }
                ]
  },
);



my $menu = $cui->add(
  'menu','Menubar', 
  -menu => \@menu,
  -fg   => "black",
  -bg   => "white",
);

my $win1 = $cui->add(
  'win1', 'Window',
  -border => 1,
  -y      => 1,
  -bfg    => 'red',
);


my $lbox = $win1->add("List", "Listbox");
$lbox->set_binding(\&mark_as_read, "r" );
$lbox->set_binding(\&delete_item, "d" );

$cui->set_binding(sub {$menu->focus()}, "\cX");
$cui->set_binding( \&exit_dialog, "\cQ");

refresh_list();

$lbox->focus();
$cui->mainloop();

##################
sub mark_as_read()
##################
{
  my $selected = $lbox->get_active_value();
  $selected =~ /.*\s(\d.*)$/;
  my $itemid = $1;
  my $text = $SEEN{$itemid};
  my($title,$price,$endtimestring,$buynow,$new,$deleted,$ended_but_refreshed) = split(/\|/,$text);
  $SEEN{$itemid} = sprintf("%s|%s|%s|%s| |%s|%s",$title,$price,$endtimestring,$buynow,$deleted,$ended_but_refreshed);
  $lbox->option_next();
  #refresh_list();
}

##################
sub delete_item()
##################
{
  my $selected = $lbox->get_active_value();
  $selected =~ /.*\s(\d.*)$/;
  my $itemid = $1;
  my $text = $SEEN{$itemid};
  my($title,$price,$endtimestring,$buynow,$new,$deleted,$ended_but_refreshed) = split(/\|/,$text);
  $SEEN{$itemid} = sprintf("%s|%s|%s|%s|%s|1|%s",$title,$price,$endtimestring,$buynow,$new,$ended_but_refreshed);
  $lbox->option_next();
  #refresh_list();
}

#################
sub exit_dialog()
#################
{
  my $return = $cui->dialog(
    -message   => "Do you really want to quit?",
    -title     => "Are you sure???", 
    -buttons   => ['yes', 'no'],
  );

  exit(0) if $return;
}



#####################
sub process_result {
#####################
  my($r) = @_;
  
  #print Dumper($r);
  #exit;

  #DEBUG "Result: ", $r->{'viewItemURL'},
    # " ", $r->{'title'},
    #" ", $r->{'itemId'},
    #" ", $r->{'sellingStatus'}->{'timeLeft'};

  # wenn wir das item schon in der DB haben, wollen wir nur den Preis aktualisieren
  if($SEEN{$r->{'itemId'}})
  {
    my $itemid = $r->{'itemId'};
    my $text = $SEEN{$itemid};
    my($title,$price,$endtimestring,$buynow,$new,$deleted,$ended_but_refreshed) = split(/\|/,$text);
  
    $price = $r->{'sellingStatus'}->{'currentPrice'}->{'content'};
  
    $SEEN{$itemid} = sprintf("%s|%s|%s|%s|%s|%s|%s",$title,$price,$endtimestring,$buynow,$new,$deleted,$ended_but_refreshed);
    
    return;
  }

  my $endtimestring = $r->{'listingInfo'}->{'endTime'};

  # build the jabber message
  my $msg = "";
  my $title = $r->{'title'};
  $title =~ s/[^[:print:]]//g;
  $title =encode($title);
  my $price = $r->{'sellingStatus'}->{'currentPrice'}->{'content'};

  # fixed price auctions should be shown in a different color
  if($r->{'listingInfo'}->{'listingType'} eq 'FixedPrice')
  {
    $msg = sprintf("%s|%s|%s|S|N| |0",$title,$price,$endtimestring);
  } else {
    $msg = sprintf("%s|%s|%s| |N| |0",$title,$price,$endtimestring);
  }
	
  #DEBUG $msg,"\n";
  $SEEN{$r->{'itemId'}} = $msg;
}


#####################
sub fetch_ebay_data()
#####################
{
  open FILE, "<$SEARCH_FILE" or die "Cannot open $SEARCH_FILE ($!)";
  my $msg;
  #my @daten;
  my @lines = <FILE>;

  my $count = 0;

  my $numLines = @lines;
  $cui->progress(
    -max => $numLines,
    -message => "Fetching Ebay Data...",
  );

 #while(<FILE>)
  foreach(@lines)
  {
    
    $cui->setprogress($count++);
    # Discard comment and empty lines
    s/^\s*#.*//;
    next if /^\s*$/;
    chomp;

    my $term = $_;
	

    # execute ebay api call
    $call->execute( 'findItemsByKeywords', { keywords => $term } );

    if ( $call->has_error() )
    {
      die "Call Failed:" . $call->errors_as_string() . " " . $term;
    }

    # getters for the response Hash
    my $hash = $call->response_hash();

    # precess each search result
    # ATTENTION: when there is only oen single result, then a hash is resturned by the API instead of an array
    if ($hash->{'searchResult'}->{'count'} == 1)
    {
      process_result($hash->{'searchResult'}->{'item'});
    } else {
      for my $result (@{$hash->{'searchResult'}->{'item'}})
      {
        process_result($result);
      }
    }
  }

  $cui->noprogress();  

  refresh_list();
}


#################
sub refresh_list
#################
{
  my @headlines;
  my %temphash;
  my $key;

#  my $tomorrow = DateTime->now->add( days => 1 )->truncate( to => 'day' );
#  my $today = DateTime->now()->truncate( to => 'day' );
#  my $yesterday = DateTime->now->subtract( days => 1 )->truncate( to => 'day' );

  my $datestring;


  foreach (keys %SEEN)
  {
    my $itemid = $_;
    my $text = $SEEN{$itemid},"\n";
    
    my($title,$price,$endtimestring,$buynow,$new,$deleted,$ended_but_refreshed) = split(/\|/,$text);	
    #DEBUG $itemid,"*", $title,"*",$price,"*",$endtimestring,"*",$buynow,"*",$new,"*",$deleted,"*",$ended_but_refreshed,"\n";
    if ($deleted eq "1") { next; }
    my $dt = DateTime::Format::ISO8601->parse_datetime($endtimestring); 
   
 #   my $day = $dt->truncate( to => 'day' );
  
 #   if ($day == $today){
 #     $datestring = "TODAY " . $dt->strftime(' %T');
 #   } elsif ($day == $tomorrow) {
 #     $datestring = "TOMORO" . $dt->strftime(' %T');
 #   } elsif ($day == $yesterday) {
 #     $datestring = "YESTER";
 #   } else {
 #     $datestring = $dt->strftime('%d.%m. %T');
 #   }

    $datestring = $dt->strftime('%d.%m. %T');
 
    my $flags = sprintf("%s%s%s", $new,$deleted,$buynow);
    my $headline = sprintf("%4.4s  %7.7s  %-45.45s  %12.12s %s",
                            $flags,$price,$title,$datestring,$itemid);
    $temphash{$dt->epoch()} = $headline;
  }

  foreach $key (sort keys %temphash) 
  {
    push(@headlines, $temphash{$key});
  }
  
  $lbox->values(\@headlines);
	
}

############
sub encode {
############
  my($text) = @_;  
  
  $text =~ s/[^\x00-\x7f]//g;
  $text =~ s/\xe4/ae/g;
  $text =~ s/\xc4/Ae/g;
  $text =~ s/\xf6/oe/g;
  $text =~ s/\xfc/ue/g;
  $text =~ s/\xdc/Ue/g;
  $text =~ s/\xdf/sz/g;
  $text =~ s/\xd6/Oe/g;
  $text =~ s/\x989e//g;
  $text =~ s/\|/ /g;
  return $text;
}


