package SOAP::Lite::Schema;
use SOAP::Lite;
use SOAP::Lite::Schema::Deserializer;
use strict;

use Carp ();

sub DESTROY { SOAP::Trace::objects('()') }

sub new {
    my $self = shift;
    return $self if ref $self;
    unless (ref $self) {
        my $class = $self;
        require LWP::UserAgent;
        $self = bless {
            '_deserializer' => SOAP::Lite::Schema::Deserializer->new,
            '_useragent'    => LWP::UserAgent->new,
        }, $class;

        SOAP::Trace::objects('()');
    }

    Carp::carp "Odd (wrong?) number of parameters in new()" if $^W && (@_ & 1);
    no strict qw(refs);
    while (@_) {
        my $method = shift;
        $self->$method(shift) if $self->can($method)
    }

    return $self;
}

sub schema {
    warn "SOAP::Lite::Schema->schema has been deprecated. "
        . "Please use SOAP::Lite::Schema->schema_url instead.";
    return shift->schema_url(@_);
}

sub BEGIN {
    no strict 'refs';
    for my $method (qw(deserializer schema_url services useragent stub cache_dir cache_ttl)) {
        my $field = '_' . $method;
        *$method = sub {
            my $self = shift->new;
            @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
        }
    }
}

sub parse {
    my $self = shift;
    my $s = $self->deserializer->deserialize($self->access)->root;
    # here should be something that defines what schema description we want to use
    $self->services({SOAP::Lite::Schema::WSDL->base($self->schema_url)->parse($s, @_)});
}

sub refresh_cache {
    my $self = shift;
    my ($filename,$contents) = @_;
    open CACHE,">$filename" or Carp::croak "Could not open cache file for writing: $!";
    print CACHE $contents;
    close CACHE;
}

sub load {
    my $self = shift->new;
    local $^W; # supress warnings about redefining
    foreach (keys %{$self->services || Carp::croak 'Nothing to load. Schema is not specified'}) {
        # TODO - check age of cached file, and delete if older than configured amount
        if ($self->cache_dir) {
            my $cached_file = File::Spec->catfile($self->cache_dir,$_.".pm");
            my $ttl = $self->cache_ttl || $SOAP::Constants::DEFAULT_CACHE_TTL;
            open (CACHE, "<$cached_file");
            my @stat = stat($cached_file) unless eof(CACHE);
            close CACHE;
            if (@stat) {
                # Cache exists
                my $cache_lived = time() - $stat[9];
                if ($ttl > 0 && $cache_lived > $ttl) {
                    $self->refresh_cache($cached_file,$self->generate_stub($_));
                }
            }
            else {
                # Cache doesn't exist
                $self->refresh_cache($cached_file,$self->generate_stub($_));
            }
            push @INC,$self->cache_dir;
            eval "require $_" or Carp::croak "Could not load cached file: $@";
        }
        else {
            eval $self->generate_stub($_) or Carp::croak "Bad stub: $@";
        }
    }
    $self;
}

sub access {
    my $self = shift->new;
    my $url = shift || $self->schema_url || Carp::croak 'Nothing to access. URL is not specified';
    $self->useragent->env_proxy if $ENV{'HTTP_proxy'};

    my $req = HTTP::Request->new(GET => $url);
    $req->proxy_authorization_basic($ENV{'HTTP_proxy_user'}, $ENV{'HTTP_proxy_pass'})
        if ($ENV{'HTTP_proxy_user'} && $ENV{'HTTP_proxy_pass'});

    my $resp = $self->useragent->request($req);
    $resp->is_success ? $resp->content : die "Service description '$url' can't be loaded: ",  $resp->status_line, "\n";
}

sub generate_stub {
    my $self = shift->new;
    my $package = shift;
    my $services = $self->services->{$package};
    my $schema_url = $self->schema_url;

    $self->{'_stub'} = <<"EOP";
package $package;
# Generated by SOAP::Lite (v$SOAP::Lite::VERSION) for Perl -- soaplite.com
# Copyright (C) 2000-2006 Paul Kulchenko, Byrne Reese
# -- generated at [@{[scalar localtime]}]
EOP
    $self->{'_stub'} .= "# -- generated from $schema_url\n" if $schema_url;
    $self->{'_stub'} .= 'my %methods = ('."\n";
    foreach my $service (keys %$services) {
        $self->{'_stub'} .= "$service => {\n";
        foreach (qw(endpoint soapaction namespace)) {
            $self->{'_stub'} .= "    $_ => '".$services->{$service}{$_}."',\n";
        }
        $self->{'_stub'} .= "    parameters => [\n";
        foreach (@{$services->{$service}{parameters}}) {
#           next unless $_;
            $self->{'_stub'} .= "      SOAP::Data->new(name => '".$_->name."', type => '".$_->type."', attr => {";
            $self->{'_stub'} .= do {
                my %attr = %{$_->attr};
                join(', ', map {"'$_' => '$attr{$_}'"}
                    grep {/^xmlns:(?!-)/}
                        keys %attr);
            };
            $self->{'_stub'} .= "}),\n";
        }
        $self->{'_stub'} .= "    ], # end parameters\n";
        $self->{'_stub'} .= "  }, # end $service\n";
    }
    $self->{'_stub'} .= "); # end my %methods\n";
    $self->{'_stub'} .= <<'EOP';

use SOAP::Lite;
use Exporter;
use Carp ();

use vars qw(@ISA $AUTOLOAD @EXPORT_OK %EXPORT_TAGS);
@ISA = qw(Exporter SOAP::Lite);
@EXPORT_OK = (keys %methods);
%EXPORT_TAGS = ('all' => [@EXPORT_OK]);

sub _call {
    my ($self, $method) = (shift, shift);
    my $name = UNIVERSAL::isa($method => 'SOAP::Data') ? $method->name : $method;
    my %method = %{$methods{$name}};
    $self->proxy($method{endpoint} || Carp::croak "No server address (proxy) specified")
        unless $self->proxy;
    my @templates = @{$method{parameters}};
    my @parameters = ();
    foreach my $param (@_) {
        if (@templates) {
            my $template = shift @templates;
            my ($prefix,$typename) = SOAP::Utils::splitqname($template->type);
            my $method = 'as_'.$typename;
            # TODO - if can('as_'.$typename) {...}
            my $result = $self->serializer->$method($param, $template->name, $template->type, $template->attr);
            push(@parameters, $template->value($result->[2]));
        }
        else {
            push(@parameters, $param);
        }
    }
    $self->endpoint($method{endpoint})
       ->ns($method{namespace})
       ->on_action(sub{qq!"$method{soapaction}"!});
EOP
    my $namespaces = $self->deserializer->ids->[1];
    foreach my $key (keys %{$namespaces}) {
        my ($ns,$prefix) = SOAP::Utils::splitqname($key);
        $self->{'_stub'} .= '  $self->serializer->register_ns("'.$namespaces->{$key}.'","'.$prefix.'");'."\n"
            if ($ns eq "xmlns");
    }
    $self->{'_stub'} .= <<'EOP';
    my $som = $self->SUPER::call($method => @parameters);
    if ($self->want_som) {
        return $som;
    }
    UNIVERSAL::isa($som => 'SOAP::SOM') ? wantarray ? $som->paramsall : $som->result : $som;
}

sub BEGIN {
    no strict 'refs';
    for my $method (qw(want_som)) {
        my $field = '_' . $method;
        *$method = sub {
            my $self = shift->new;
            @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
        }
    }
}
no strict 'refs';
for my $method (@EXPORT_OK) {
    my %method = %{$methods{$method}};
    *$method = sub {
        my $self = UNIVERSAL::isa($_[0] => __PACKAGE__)
            ? ref $_[0]
                ? shift # OBJECT
                # CLASS, either get self or create new and assign to self
                : (shift->self || __PACKAGE__->self(__PACKAGE__->new))
            # function call, either get self or create new and assign to self
            : (__PACKAGE__->self || __PACKAGE__->self(__PACKAGE__->new));
        $self->_call($method, @_);
    }
}

sub AUTOLOAD {
    my $method = substr($AUTOLOAD, rindex($AUTOLOAD, '::') + 2);
    return if $method eq 'DESTROY' || $method eq 'want_som';
    die "Unrecognized method '$method'. List of available method(s): @EXPORT_OK\n";
}

1;
EOP
    return $self->stub;
}

1;

__END__