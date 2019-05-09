package LaTeXML::Plugin::LtxMojo;
use Mojo::Base 'Mojolicious';
use Mojo::File 'path';
use Mojo::Home;
use Mojo::JSON;
use Mojo::IOLoop;
use Mojo::ByteStream qw(b);

use File::Basename 'dirname';
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

use Archive::Zip qw(:CONSTANTS :ERROR_CODES);
use IO::String;
use Encode qw(decode encode);

use LaTeXML::Common::Config;
use LaTeXML::Util::Pathname qw(pathname_protocol);
use LaTeXML;
use LaTeXML::Plugin::LtxMojo::Startup;

our $dbfile  = '.LaTeXML_Mojo.cache';

# Every CPAN module needs a version
our $VERSION = '0.4';

# This method will run once at server start
sub startup {
my $app = shift;

# Switch to installable home directory
$app->home(Mojo::Home->new(path(__FILE__)->sibling('LtxMojo')));

# Switch to installable "public" directory
$app->static->paths->[0] = $app->home->child('public');

# Switch to installable "templates" directory
$app->renderer->paths->[0] = $app->home->child('templates');

$ENV{MOJO_MAX_MESSAGE_SIZE} = 107374182; # close to 100 MB file upload limit
$ENV{MOJO_REQUEST_TIMEOUT} = 600;# 10 minutes;
$ENV{MOJO_CONNECT_TIMEOUT} = 120; # 2 minutes
$ENV{MOJO_INACTIVITY_TIMEOUT} = 600; # 10 minutes;

# We DO NOT USE cookies.
$app->secrets([rand]);

#Prep a LaTeXML Startup instance
my $startup = LaTeXML::Plugin::LtxMojo::Startup->new(dbfile => catfile($app->home,$dbfile));

$app->helper(convert_zip => sub {
  my ($self) = @_;
  # Make sure we point to the actual source directory
  my $name = $self->req->headers->header('x-file-name');
  $name =~ s/\.zip$//;
  # HTTP GET parameters hold the conversion options
  my @all_params = @{ $self->req->url->query->pairs || [] };
  my $opts=[];
  # Ugh, disallow 'null' as a value!!! (TODO: Smarter fix??)
  while (my ($key,$value) = splice(@all_params,0,2)) {
    if ($key=~/^(?:local|path|destination|directory)$/) {
      # You don't get to specify harddrive info in the web service
      next; }
    $value = '' if ($value && ($value  eq 'null'));
    push @$opts, ($key,$value); }

  my $config = LaTeXML::Common::Config->new();
  my $config_build_return = eval {
    $config->read_keyvals($opts, silent=>1); };
  if (!$config_build_return || $@) {
    # ... error handling
    # and premature exit from the code block
    $@ = "See 'latexmlc --help' for the full options specification" unless $@;
    return $self->render(json => {
      status_code=>3,
      status=>"Fatal:http:request You have used illegal or ill-formed options in your request.",
      log=>"Fatal:http:request You have used illegal or ill-formed options in your request.\nDetails: $@\nStatus:conversion:3"});
  }

  my @latexml_inputs = ('.',grep {defined} split(':',($ENV{LATEXMLINPUTS}||'')));
  $config->set('paths',\@latexml_inputs);
  $config->set('whatsin','archive');
  $config->set('whatsout','archive');
  $config->set('log',"$name.log");
  $config->set('local',($self->tx->remote_address eq '127.0.0.1'));
  # Only HTML5 for now.
  $config->set('format','html5');
  # Prepare and convert
  my $converter = LaTeXML->get_converter($config);
  $converter->prepare_session($config);
  my $source = $self->req->body;
  $source = "literal:".$source if ($source && (pathname_protocol($source) eq 'file'));
  my $response = $converter->convert($source);
  # Catch errors
  $self->render(json=>{status_code=>3,log=>'Fatal: Internal Conversion Error, please contact the administrator.'}) unless
    (defined $response && ($response->{result}));
  # Return
  my $headers = Mojo::Headers->new;
  $headers->add('Content-Type',"application/zip;name=$name.zip");
  $headers->add('Content-Disposition',"attachment;filename=$name.zip");
  $self->res->content->headers($headers);
  return $self->render(data=>$response->{result});
});

$app->helper(convert_string => sub {
  my ($self) = @_;
  my ($source,$is_jsonp);
  my $get_params = $self->req->url->query->pairs || [];
  my $post_params = $self->req->body_params->pairs || [];
  if (scalar(@$post_params) == 1) {
    $source = $post_params->[0];
    $post_params=[];
  } elsif ((scalar(@$post_params) == 2) && ($post_params->[0] !~ /^(?:tex|source)$/)) {
    $source = $post_params->[0].$post_params->[1];
    $post_params=[];
  }
  # We need to be careful to preserve the parameter order, so use arrayrefs
  my @all_params = (@$get_params, @$post_params);
  my $opts = [];
  # Ugh, disallow 'null' as a value!!! (TODO: Smarter fix??)
  while (my ($key,$value) = splice(@all_params,0,2)) {
    # JSONP ?
    if ($key eq 'jsonp') {
      $is_jsonp = $value;
      next;
    } elsif ($key =~ /^(?:tex|source)$/) {
      # TeX is data, separate
      $source = $value unless defined $source;
      next;
    } elsif ($key=~/^(?:local|path|destination|directory)$/) {
      # You don't get to specify harddrive info in the web service
      next;
    } elsif ($key=~/^(?:preamble|postamble)$/) {
      $value = "literal:".$value if ($value && (pathname_protocol($value) eq 'file'));
    }
    $value = '' if ($value && ($value  eq 'null'));
    $key=~s/\[\]$//; # strip array suffix for e.g. preamble[]
    push @$opts, ($key,$value);
  }

  my $config = LaTeXML::Common::Config->new();
  my $config_build_return = eval {
    $config->read_keyvals($opts, silent=>1); };
  if (!$config_build_return || $@) {
    # ... error handling
    # and premature exit from the code block
    $@ = "See 'latexmlc --help' for the full options specification" unless $@;
    return $self->render(json=>{status_code=>3,log=>"Fatal: You have used illegal or ill-formed options in your request.".
    "\nDetails:\n$@\n"});
  }
  # We now have a LaTeXML config object - $config.
  my @latexml_inputs = grep {defined} split(':',($ENV{LATEXMLINPUTS}||''));
  $config->set('paths',\@latexml_inputs);
  my $converter = LaTeXML->get_converter($config);

  #Override/extend with session-specific options in $opt:
  $converter->prepare_session($config);
  # If there are no protocols, use literal: as default:
  if ((! defined $source) || (length($source)<1)) {
    $self->render(json => {result => '', status => "Fatal:input:empty No TeX provided on input", status_code=>3,
                           log => "Status:conversion:3\nFatal:input:empty No TeX provided on input"});
  } else {
    $source = "literal:".$source if ($source && (pathname_protocol($source) eq 'file'));
    $source = encode("UTF-8", $source);
    #Send a request:
    my $response = $converter->convert($source);
    my ($result, $status, $status_code, $log);
    if (defined $response) {
      ($result, $status, $status_code, $log) = map { $response->{$_} } qw(result status status_code log);
    }
    # Delete converter if Fatal occurred
    undef $converter unless defined $result;
    if ($is_jsonp) {
        my $json_result = $self->render(
  	  json => {result => $result,
  		   status => $status, status_code=>$status_code, log => $log, partial=>1});
        $self->render(data => "$is_jsonp($json_result)", format => 'js');
    } elsif ($config->get('whatsout') eq 'archive') { # Archive conversion returns a ZIP
      $self->render(data => $result);
    } else {
      # Ok we need to avoid a double UTF-8 encode by mojolicious. To do this, decode the result
      if ($result) {
        $result = decode("UTF-8", $result);
      }
      $self->render(json => {result => $result, status => $status, status_code=>$status_code, log => $log});
    }
  }
});


################################################
##                                            ##
##              ROUTES                        ##
##                                            ##
################################################
my $r = $app->routes;
$r->post('/convert' => sub {
  my $self = shift;
  my $type = $self->req->headers->header('x-file-type');
  if ($type && $type =~ 'zip' && ($self->req->headers->header('content-type') eq 'multipart/form-data')) {
    $self->convert_zip;
  } else {
    $self->convert_string;
  }
});

$r->websocket('/convert' => sub {
  my $self  = shift;
  my $json = Mojo::JSON->new;
  # Connected
  $self->app->log->debug('WebSocket connected.');
  # Increase inactivity timeout for connection a bit
  Mojo::IOLoop->stream($self->tx->connection)->timeout(300);
  $self->on('message' => sub {
	      my ($tx, $bytes) = @_;
	      #TODO: We want the options in the right order, is this Decode safe in this respect?
	      my $opts = $json->decode($bytes);
	      my $source = $opts->{source}; delete $opts->{source};
	      $source = $opts->{tex} unless defined $opts->{source}; delete $opts->{tex};
	      my $config = LaTeXML::Common::Config->new();
        my $config_build_return = eval {
          $config->read_keyvals([%$opts], silent=>1); };
        if (!$config_build_return || $@) {
          # ... error handling
          # and premature exit from the code block
          $@ = "See 'latexmlc --help' for the full options specification" unless $@;
          return $$tx->send({text=>$json->encode(status_code=>3,log=>"Fatal: You have used illegal or ill-formed options in your request.".
            "\nDetails:\n$@\n")});
        }
	      # We now have a LaTeXML options object - $opt.
	      my $converter = LaTeXML->get_converter($config);
	      #Override/extend with session-specific options in $opt:
	      $converter->prepare_session($config);
	      #Send a request:
	      my $response = $converter->convert($source);
	      my ($result, $status, $log);
	      if (defined $response) {
		      if (! defined $response->{result}) {
		      # Delete converter if Fatal occurred
		      undef $converter;
		      } else {
		        #$response->{result} = decode('UTF-8',$response->{result});
		      }
	      }
	      $tx->send({text=>$json->encode($response)});
	    });
  # Disconnected
  $self->on('finish' => sub {
	      my $self = shift;
	      $self->app->log->debug('WebSocket disconnected.');
	    });
});

$r->get('/about' => sub {
  my $self    = shift;
  my $headers = Mojo::Headers->new;
  $headers->add('Content-Type', 'application/xhtml+xml');
  $self->res->content->headers($headers);
  $self->render();
} => 'about');

$r->get('/demo' => sub {
  my $self = shift;
} => 'demo');

$r->get('/editor' => sub {
  my $self    = shift;
  my $headers = Mojo::Headers->new;
  $headers->add('Content-Type', 'text/html');
  $self->res->content->headers($headers);
  $self->render();
} => 'editor');

$r->get('/' => sub {
  my $self = shift;
  return $self->redirect_to('about');
});

$r->get('/help' => sub {
  my $self = shift;
  $self->render;
} => 'help');


$r->get('/upload' => sub {
  my $self = shift;
  $self->render;
} => 'upload');

$r->post('/upload' => sub {
  my $self = shift;
  # TODO: Need a session?
  my $type = $self->req->headers->header('x-file-type');
  if ($type && $type =~ 'zip' && ($self->req->headers->header('content-type') eq 'multipart/form-data')) {
    $self->convert_zip;
  } else {
    #.tex , .sty , .jpg and so on - write to filesystem (when are we done?)
    $self->render(text=>"Uploaded, but ignored!");
  }
});

}
1;

__END__

=pod

=head1 NAME

C<ltxmojo> - A web server for the LaTeXML suite.

=head1 DESCRIPTION

L<ltxmojo> is a Mojolicious::Lite web application that builds on LateXML to provide
on demand TeX to XML conversion as a scalable web service.

The service comes together with a collection of convenient interfaces, conversion examples,
as well as an administration system for user and transformation profile management.

=head1 ROUTES

The following routes are supported:

=over 4

=item C< / >

Root route, redirects to /about

=item C</about>

On HTTP GET, provides a brief summary of the web service functionality.

=item C</admin>

On HTTP GET, provides an administrative interface for managing user and profile data, as well
as to examine the overal system status.

=item C</convert>

Accepts HTTP POST requests to perform conversion jobs.

The request syntax supports the normal key=value option fields for L<LaTeXML>.

Additionally, one can request embeddable snippets via I<embed=1>,
 as well as forced xml:id attributes on every element via I<force_ids=1>.
Supported via L<LaTeXML::Util::Extras>.

The most significant enhancements are in provdiding options for user and conversion profiles,
namely I<user=string>, I<password=string> and I<profile=string>.
Based on the sessioning functionality enabled by L<LaTeXML::Util::Startup>, a user can now
easily perform conversions based on his custom preferences. Moreover, conversion profiles allow
for users to obtain the desired transformation setup with just specifying a single "profile" field.
For a list of predefined profiles, consult L<LaTeXML::Util::Startup>.

The actual TeX/LaTeX source to be converted should be sent serialized as C<tex=content>.

=item C</editor>

Provides an AJAX and jQuery-based editor, originally created by Heinrich Stamerjohanns,
to showcase on-the-fly conversion of LaTeX snippets to XHTML.
A set of illustrating examples is provided, as well as a
convenient integration with LaTeXML's log and status reports.

A jQuery conversion request is as simple as:

 $.post("/convert", { "tex": tex, "profile":"fragment"});

=item C</help>

Help page, providing a guide through the site's functionality.

=item C</login>

A simple login interface.

=item C</logout>

A simple logout route that ends the current session.

=item C</upload>

On HTTP GET, this route provides an interface for converting LaTeX files, or entire setups,
by accepting .zip and .tar.gz archives, as well as mutlipart uploads of several file fragments,
as long as no subdirectories are present. Note that this is achieved with HTML5's native support
for multipart file uploads, hence a modern browser is required.

On HTTP POST, the uploaded bundle is converted by the server, returning an archive with the result.

=back

=head1 DEPLOYMENT

Installation and deployment are described in detail in LaTeXML/webapp/INSTALL.

As a rule of thumb, the regular deployment process for Mojolicious apps applies.


=head1 SEE ALSO

L<latexmls>, L<latexmlc>, L<LaTeXML>

=head1 AUTHOR

Deyan Ginev <d.ginev@jacobs-university.de>

=head1 COPYRIGHT

Public domain software, produced as part of work done by the
United States Government & not subject to copyright in the US.

=cut
