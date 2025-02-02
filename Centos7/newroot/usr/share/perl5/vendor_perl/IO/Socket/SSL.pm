# vim: set sts=4 sw=4 ts=8 ai:
#
# IO::Socket::SSL:
# provide an interface to SSL connections similar to IO::Socket modules
#
# Current Code Shepherd: Steffen Ullrich <sullr at cpan.org>
# Code Shepherd before: Peter Behroozi, <behrooz at fas.harvard.edu>
#
# The original version of this module was written by
# Marko Asplund, <marko.asplund at kronodoc.fi>, who drew from
# Crypt::SSLeay (Net::SSL) by Gisle Aas.
#

package IO::Socket::SSL;

use IO::Socket;
use Net::SSLeay 1.21;
use Exporter ();
use Errno qw( EAGAIN ETIMEDOUT );
use Carp;
use strict;

our $VERSION = '1.94';

use constant SSL_VERIFY_NONE => Net::SSLeay::VERIFY_NONE();
use constant SSL_VERIFY_PEER => Net::SSLeay::VERIFY_PEER();
use constant SSL_VERIFY_FAIL_IF_NO_PEER_CERT => Net::SSLeay::VERIFY_FAIL_IF_NO_PEER_CERT();
use constant SSL_VERIFY_CLIENT_ONCE => Net::SSLeay::VERIFY_CLIENT_ONCE();

# from openssl/ssl.h; should be better in Net::SSLeay
use constant SSL_SENT_SHUTDOWN => 1;
use constant SSL_RECEIVED_SHUTDOWN => 2;

# global defaults
my %DEFAULT_SSL_ARGS = (
    SSL_check_crl => 0,
    SSL_version => '',
    SSL_verify_callback => undef,
    SSL_verifycn_scheme => undef,  # don't verify cn
    SSL_verifycn_name => undef,    # use from PeerAddr/PeerHost
    SSL_npn_protocols => undef,    # meaning depends whether on server or client side
    SSL_honor_cipher_order => 0,   # client order gets preference
    SSL_cipher_list => undef,

    # default for SSL_verify_mode should be SSL_VERIFY_PEER for client
    # for now we keep the default of SSL_VERIFY_NONE but complain, if 
    # somebody uses this implicit default
    # SSL_verify_mode => undef,  # set to undef to enable secure default
    SSL_verify_mode => SSL_VERIFY_NONE,
);

# global defaults which can be changed using set_defaults
# either key/value can be set or it can just be set to an external hash
my $GLOBAL_SSL_ARGS = {};

# non-XS Versions of Scalar::Util will fail
BEGIN{
    local $SIG{__DIE__}; local $SIG{__WARN__}; # be silent
    eval { use Scalar::Util 'dualvar'; dualvar(0,'') };
    die "You need the XS Version of Scalar::Util for dualvar() support"
	if $@;
}

# get constants for SSL_OP_NO_* now, instead calling the releated functions
# everytime we setup a connection
my %SSL_OP_NO;
for(qw( SSLv2 SSLv3 TLSv1 TLSv1_1 TLSv11:TLSv1_1 TLSv1_2 TLSv12:TLSv1_2 )) {
    my ($k,$op) = m{:} ? split(m{:},$_,2) : ($_,$_);
    my $sub = "Net::SSLeay::OP_NO_$op";
    $SSL_OP_NO{$k} = eval { no strict 'refs'; &$sub } || 0;
}

our $DEBUG;
use vars qw(@ISA $SSL_ERROR @EXPORT );

{
    # These constants will be used in $! at return from SSL_connect,
    # SSL_accept, generic_read and write, thus notifying the caller
    # the usual way of problems. Like with EAGAIN, EINPROGRESS..
    # these are especially important for non-blocking sockets

    my $x = Net::SSLeay::ERROR_WANT_READ();
    use constant SSL_WANT_READ  => dualvar( \$x, 'SSL wants a read first' );
    my $y = Net::SSLeay::ERROR_WANT_WRITE();
    use constant SSL_WANT_WRITE => dualvar( \$y, 'SSL wants a write first' );

    @EXPORT = qw(
	SSL_WANT_READ SSL_WANT_WRITE SSL_VERIFY_NONE SSL_VERIFY_PEER
	SSL_VERIFY_FAIL_IF_NO_PEER_CERT SSL_VERIFY_CLIENT_ONCE
	$SSL_ERROR GEN_DNS GEN_IPADD
    );
}

my @caller_force_inet4; # in case inet4 gets forced we store here who forced it

BEGIN {
    # declare @ISA depending of the installed socket class

    # try to load inet_pton from Socket or Socket6
    local $SIG{__DIE__}; local $SIG{__WARN__}; # be silent
    my $ip6 = eval {
	require Socket;
	Socket->VERSION(1.95);
	Socket->import( qw/inet_pton getnameinfo NI_NUMERICHOST NI_NUMERICSERV/ );
	AF_INET6(); # >0 if defined in IO::Socket
    } || eval {
	require Socket6;
	Socket6->import( qw/inet_pton getnameinfo NI_NUMERICHOST NI_NUMERICSERV/ );
	AF_INET6(); # >0 if defined in IO::Socket
    };

    # try IO::Socket::IP or IO::Socket::INET6 for IPv6 support
    if ( $ip6 ) {

	# if we have IO::Socket::IP >= 0.20 we will use this in preference
	# because it can handle both IPv4 and IPv6
	if ( eval { require IO::Socket::IP; IO::Socket::IP->VERSION(0.20); } ) {
	    @ISA = qw(IO::Socket::IP);
	    constant->import( CAN_IPV6 => "IO::Socket::IP" );

	# if we have IO::Socket::INET6 we will use this not IO::Socket::INET
	# because it can handle both IPv4 and IPv6
	} elsif( eval { require IO::Socket::INET6; } ) {
	    @ISA = qw(IO::Socket::INET6);
	    constant->import( CAN_IPV6 => "IO::Socket::INET6" );
	} else {
	    $ip6 = 0;
	}
    }

    # fall back to IO::Socket::INET for IPv4 only
    if ( ! $ip6 ) {
	@ISA = qw(IO::Socket::INET);
	constant->import( CAN_IPV6 => '' );
    }

    #Make $DEBUG another name for $Net::SSLeay::trace
    *DEBUG = \$Net::SSLeay::trace;

    #Compability
    *ERROR = \$SSL_ERROR;

    # Do Net::SSLeay initialization
    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::OpenSSL_add_all_digests();
    Net::SSLeay::randomize();
}

sub DEBUG {
    $DEBUG or return; 
    my (undef,$file,$line) = caller;
    my $msg = shift;
    $file = '...'.substr( $file,-17 ) if length($file)>20;
    $msg = sprintf $msg,@_ if @_;
    print STDERR "DEBUG: $file:$line: $msg\n";
}

BEGIN {
    # import some constants from Net::SSLeay or use hard-coded defaults
    # if Net::SSLeay isn't recent enough to provide the constants
    my %const = (
	NID_CommonName => 13,
	GEN_DNS => 2,
	GEN_IPADD => 7,
    );
    while ( my ($name,$value) = each %const ) {
	no strict 'refs';
	*{$name} = UNIVERSAL::can( 'Net::SSLeay', $name ) || sub { $value };
    }

    # check if we have something to handle IDN
    local $SIG{__DIE__}; local $SIG{__WARN__}; # be silent
    if ( eval { require Net::IDN::Encode }) {
	*{idn_to_ascii} = \&Net::IDN::Encode::domain_to_ascii;
    } elsif ( eval { require Net::LibIDN }) {
	*{idn_to_ascii} = \&Net::LibIDN::idn_to_ascii;
    } elsif ( eval { require URI; URI->VERSION(1.50) }) {
	    *{idn_to_ascii} = sub { URI->new("http://" . shift)->host }
    } else {
	# default: croak if we really got an unencoded international domain
	*{idn_to_ascii} = sub {
	    my $domain = shift;
	    return $domain if $domain =~m{^[a-zA-Z0-9-_\.]+$};
	    croak "cannot handle international domains, please install Net::LibIDN, Net::IDN::Encode or URI"
	}
    }
}

my $can_client_sni;  # do we support SNI on the client side
my $can_server_sni;  # do we support SNI on the server side
my $can_npn;         # do we support NPN
BEGIN {
    $can_client_sni = Net::SSLeay::OPENSSL_VERSION_NUMBER() >= 0x01000000;
    $can_server_sni = defined &Net::SSLeay::get_servername;
    $can_npn        = defined &Net::SSLeay::P_next_proto_negotiated;
}

# Export some stuff
# inet4|inet6|debug will be handled by myself, everything
# else will be handled the Exporter way
sub import {
    my $class = shift;

    my @export;
    foreach (@_) {
	if ( /^inet4$/i ) {
	    # explicitly fall back to inet4
	    @ISA = 'IO::Socket::INET';
	    @caller_force_inet4 = caller(); # save for warnings for 'inet6' case
	} elsif ( /^inet6$/i ) {
	    # check if we have already ipv6 as base
	    if ( ! UNIVERSAL::isa( $class, 'IO::Socket::INET6')
		and ! UNIVERSAL::isa( $class, 'IO::Socket::IP' )) {
		# either we don't support it or we disabled it by explicitly
		# loading it with 'inet4'. In this case re-enable but warn
		# because this is probably an error
		if ( CAN_IPV6 ) {
		    @ISA = ( CAN_IPV6 );
		    warn "IPv6 support re-enabled in __PACKAGE__, got disabled in file $caller_force_inet4[1] line $caller_force_inet4[2]";
		} else {
		    die "INET6 is not supported, install IO::Socket::INET6";
		}
	    }
	} elsif ( /^:?debug(\d+)/ ) {
	    $DEBUG=$1;
	} else {
	    push @export,$_
	}
    }

    @_ = ( $class,@export );
    goto &Exporter::import;
}

my %CREATED_IN_THIS_THREAD;
sub CLONE { %CREATED_IN_THIS_THREAD = (); }

# You might be expecting to find a new() subroutine here, but that is
# not how IO::Socket::INET works.  All configuration gets performed in
# the calls to configure() and either connect() or accept().

#Call to configure occurs when a new socket is made using
#IO::Socket::INET.  Returns false (empty list) on failure.
sub configure {
    my ($self, $arg_hash) = @_;
    return _invalid_object() unless($self);

    # work around Bug in IO::Socket::INET6 where it doesn't use the
    # right family for the socket on BSD systems:
    # http://rt.cpan.org/Ticket/Display.html?id=39550
    if ( CAN_IPV6 eq "IO::Socket::INET6" && ! $arg_hash->{Domain} &&
	! ( $arg_hash->{LocalAddr} || $arg_hash->{LocalHost} ) &&
	(my $peer = $arg_hash->{PeerAddr} || $arg_hash->{PeerHost})) {
	# set Domain to AF_INET/AF_INET6 if there is only one choice
	($peer, my $port) = IO::Socket::INET6::_sock_info( $peer,$arg_hash->{PeerPort},6 );
	my @res = Socket6::getaddrinfo( $peer,$port,AF_UNSPEC,SOCK_STREAM );
	if (@res == 5) {
	    $arg_hash->{Domain} = $res[0];
	    $DEBUG>=2 && DEBUG('set domain to '.$res[0] );
	}
    }

    # force initial blocking
    # otherwise IO::Socket::SSL->new might return undef if the
    # socket is nonblocking and it fails to connect immediately
    # for real nonblocking behavior one should create a nonblocking
    # socket and later call connect explicitly
    my $blocking = delete $arg_hash->{Blocking};

    # because Net::HTTPS simple redefines blocking() to {} (e.g
    # return undef) and IO::Socket::INET does not like this we

    # set Blocking only explicitly if it was set
    $arg_hash->{Blocking} = 1 if defined ($blocking);

    $self->configure_SSL($arg_hash) || return;

    $self->SUPER::configure($arg_hash)
	|| return $self->error("@ISA configuration failed");

    $self->blocking(0) if defined $blocking && !$blocking;
    return $self;
}

sub configure_SSL {
    my ($self, $arg_hash) = @_;
    my $is_server = $arg_hash->{'SSL_server'} || $arg_hash->{'Listen'} || 0;

    # add user defined defaults
    %$arg_hash = ( 
	%$GLOBAL_SSL_ARGS, 
	%$arg_hash 
    ) if %$GLOBAL_SSL_ARGS;

    # common problem forgetting to set SSL_use_cert
    # if client cert is given by user but SSL_use_cert is undef, assume that it
    # should be set
    if ( ! $is_server && ! defined $arg_hash->{SSL_use_cert}
	&& ( grep { $arg_hash->{$_} } qw(SSL_cert SSL_cert_file))
	&& ( grep { $arg_hash->{$_} } qw(SSL_key SSL_key_file)) ) {
	$arg_hash->{SSL_use_cert} = 1
    }

    # library defaults
    my %default_args = (
	Proto => 'tcp',
	SSL_server => $is_server,
	SSL_use_cert => $is_server,
	%DEFAULT_SSL_ARGS,
    );

    # make default secure, unless it was set different before
    $default_args{SSL_verify_mode} = $is_server ? SSL_VERIFY_NONE : SSL_VERIFY_PEER
	if ! defined $default_args{SSL_verify_mode};

    # complain if SSL_verify_mode is SSL_VERIFY_NONE for client unless it 
    # was explicitly set this way. In the future the default will change 
    # to verify the server certificate and apps, which don't provide 
    # the necessary credentials should fail
    if ( ! $is_server 
	and ! $arg_hash->{SSL_reuse_ctx} 
	and ! exists $arg_hash->{SSL_verify_mode} 
	and $default_args{SSL_verify_mode} == SSL_VERIFY_NONE ) {
	carp(
	    "*******************************************************************\n".
	    " Using the default of SSL_verify_mode of SSL_VERIFY_NONE for client\n".
	    " is deprecated! Please set SSL_verify_mode to SSL_VERIFY_PEER\n".
	    " possibly with SSL_ca_file|SSL_ca_path for verification.\n".
	    " If you really don't want to verify the certificate and keep the\n".
	    " connection open to Man-In-The-Middle attacks please set\n".
	    " SSL_verify_mode explicitly to SSL_VERIFY_NONE in your application.\n".
	    "*******************************************************************\n".
	    " "
	);
    }

    # add defaults to arg_hash
    %$arg_hash = ( %default_args, %$arg_hash );

    # use default path to certs and ca unless another one was given
    # don't mix default paths with user specified paths for CA or client
    # certificates, either we use all from the grup or no defaults
    {
	my $use_default_ca = 1;
	my $dont_use_system_ca_file = (exists $arg_hash->{SSL_ca_file} and
		not defined($arg_hash->{SSL_ca_file}));
	for (qw( SSL_ca_file SSL_ca_path )) {
	    next if ! defined $arg_hash->{$_};
	    # some apps set keys '' to signal that it is not set, replace with undef
	    if ( $arg_hash->{$_} eq '' ) {
		$arg_hash->{$_} = undef;
		next;
	    }
	    $use_default_ca = 0;
	}
	my $use_default_client = 1;
	for (qw( SSL_cert SSL_cert_file SSL_key SSL_key_file )) {
	    next if ! defined $arg_hash->{$_};
	    # some apps set keys '' to signal that it is not set, replace with undef
	    if ( $arg_hash->{$_} eq '' ) {
		$arg_hash->{$_} = undef;
		next;
	    }
	    $use_default_client = 0;
	}
	if ( $use_default_ca ) {
	    my %ca = 
		-f 'certs/my-ca.pem' ? ( SSL_ca_file => 'certs/my-ca.pem' ) :
		-d 'ca/' ? ( SSL_ca_path => 'ca/' ) :
		();
	    if (! %ca and !$dont_use_system_ca_file) {
		require Mozilla::CA;
		%ca = ( SSL_ca_file => Mozilla::CA::SSL_ca_file() );
	    }
	    %$arg_hash = ( %$arg_hash, %ca );
	} else {
	    if ( defined( my $f = $arg_hash->{SSL_ca_file} )) {
		die "SSL_ca_file $f does not exist" if ! -f $f;
		die "SSL_ca_file $f is not accessable" if ! -r _;
	    }
	    if ( defined( my $d = $arg_hash->{SSL_ca_path} )) {
		die "only SSL_ca_path or SSL_ca_file should be given"
		    if defined $arg_hash->{SSL_ca_file};
		die "SSL_ca_path $d does not exist" if ! -d $d;
		die "SSL_ca_path $d is not accessable" if ! -r _;
	    }
	}
	if ( $use_default_client ) {
	    my %certs = $is_server ? (
		SSL_key_file => 'certs/server-key.pem',
		SSL_cert_file => 'certs/server-cert.pem',
	    ) : (
		SSL_key_file => 'certs/client-key.pem',
		SSL_cert_file => 'certs/client-cert.pem',
	    );
	    %$arg_hash = ( %$arg_hash, %certs );
	} else {
	    for(qw(SSL_cert_file SSL_key_file)) {
		defined( my $file = $arg_hash->{$_} ) or next;
		for my $f (ref($file) eq 'HASH' ? values(%$file):$file ) {
		    die "$_ $f does not exist" if ! -f $f;
		    die "$_ $f is not accessable" if ! -r _;
		}
	    }
	}
    }

    #Avoid passing undef arguments to Net::SSLeay
    defined($arg_hash->{$_}) or delete($arg_hash->{$_}) foreach (keys %$arg_hash);

    my $vcn_scheme = delete $arg_hash->{SSL_verifycn_scheme};
    if ( $vcn_scheme && $vcn_scheme ne 'none' ) {
	# don't access ${*self} inside callback - this seems to create
	# circular references from the ssl object to the context and back

	# use SSL_verifycn_name or determine from PeerAddr
	my $host = $arg_hash->{SSL_verifycn_name};
	if (not defined($host)) {
	    if ( $host = $arg_hash->{PeerAddr} || $arg_hash->{PeerHost} ) {
		$host =~s{:[a-zA-Z0-9_\-]+$}{};
	    }
	}
	$host ||= ref($vcn_scheme) && $vcn_scheme->{callback} && 'unknown';
	$host or return $self->error( "Cannot determine peer hostname for verification" );

	my $vcb = $arg_hash->{SSL_verify_callback};
	$arg_hash->{SSL_verify_callback} = sub {
	    my ($ok,$ctx_store,$certname,$error,$cert) = @_;
	    $ok = $vcb->($ok,$ctx_store,$certname,$error,$cert) if $vcb;
	    $ok or return 0;
	    my $depth = Net::SSLeay::X509_STORE_CTX_get_error_depth($ctx_store);
	    return $ok if $depth != 0;

	    # verify name
	    my $rv = verify_hostname_of_cert( $host,$cert,$vcn_scheme );
	    # just do some code here against optimization because x509 has no
	    # increased reference and CRYPTO_add is not available from Net::SSLeay
	    return $rv;
	};
    }

    ${*$self}{'_SSL_arguments'} = $arg_hash;
    ${*$self}{'_SSL_ctx'} = IO::Socket::SSL::SSL_Context->new($arg_hash) || return;
    ${*$self}{'_SSL_opened'} = 1 if $is_server;

    return $self;
}


sub _set_rw_error {
    my ($self,$ssl,$rv) = @_;
    my $err = Net::SSLeay::get_error($ssl,$rv);
    $SSL_ERROR =
	$err == Net::SSLeay::ERROR_WANT_READ()  ? SSL_WANT_READ :
	$err == Net::SSLeay::ERROR_WANT_WRITE() ? SSL_WANT_WRITE :
	return;
    $! ||= EAGAIN;
    ${*$self}{'_SSL_last_err'} = $SSL_ERROR if ref($self);
    return 1;
}


#Call to connect occurs when a new client socket is made using
#IO::Socket::INET
sub connect {
    my $self = shift || return _invalid_object();
    return $self if ${*$self}{'_SSL_opened'};  # already connected

    if ( ! ${*$self}{'_SSL_opening'} ) {
	# call SUPER::connect if the underlying socket is not connected
	# if this fails this might not be an error (e.g. if $! = EINPROGRESS
	# and socket is nonblocking this is normal), so keep any error
	# handling to the client
	$DEBUG>=2 && DEBUG('socket not yet connected' );
	$self->SUPER::connect(@_) || return;
	$DEBUG>=2 && DEBUG('socket connected' );

	# IO::Socket works around systems, which return EISCONN or similar
	# on non-blocking re-connect by returning true, even if $! is set
	# but it does not clear $!, so do it here
	$! = undef;
    }
    return $self->connect_SSL;
}


sub connect_SSL {
    my $self = shift;
    my $args = @_>1 ? {@_}: $_[0]||{};

    my ($ssl,$ctx);
    if ( ! ${*$self}{'_SSL_opening'} ) {
	# start ssl connection
	$DEBUG>=2 && DEBUG('ssl handshake not started' );
	${*$self}{'_SSL_opening'} = 1;
	my $arg_hash = ${*$self}{'_SSL_arguments'};

	my $fileno = ${*$self}{'_SSL_fileno'} = fileno($self);
	return $self->error("Socket has no fileno") unless (defined $fileno);

	$ctx = ${*$self}{'_SSL_ctx'};  # Reference to real context
	$ssl = ${*$self}{'_SSL_object'} = Net::SSLeay::new($ctx->{context})
	    || return $self->error("SSL structure creation failed");
	$CREATED_IN_THIS_THREAD{$ssl} = 1;

	Net::SSLeay::set_fd($ssl, $fileno)
	    || return $self->error("SSL filehandle association failed");

	if ( my $cl = $arg_hash->{SSL_cipher_list} ) {
	    Net::SSLeay::set_cipher_list($ssl, $cl )
		|| return $self->error("Failed to set SSL cipher list");
	}

	if ( $can_client_sni ) {
	    my $host;
	    if ( exists $arg_hash->{SSL_hostname} ) {
		# explicitly given
		# can be set to undef/'' to not use extension
		$host = $arg_hash->{SSL_hostname}
	    } elsif ( $host = $arg_hash->{PeerAddr} || $arg_hash->{PeerHost} ) {
		# implicitly given
		$host =~s{:[a-zA-Z0-9_\-]+$}{};
		# should be hostname, not IPv4/6
		$host = undef if $host !~m{[a-z_]} or $host =~m{:};
	    }
	    # define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
	    # define TLSEXT_NAMETYPE_host_name 0
	    if ($host) {
		$DEBUG>=2 && DEBUG("using SNI with hostname $host");
		Net::SSLeay::ctrl($ssl,55,0,$host);
	    } else {
		$DEBUG>=2 && DEBUG("not using SNI because hostname is unknown");
	    }
	} elsif ( $arg_hash->{SSL_hostname} ) {
	    return $self->error(
		"Client side SNI not supported for this openssl");
	} else {
	    $DEBUG>=2 && DEBUG("not using SNI because openssl is too old");
	}

	$arg_hash->{PeerAddr} || $self->_update_peer;
	my $session = $ctx->session_cache( $arg_hash->{PeerAddr}, $arg_hash->{PeerPort} );
	Net::SSLeay::set_session($ssl, $session) if ($session);
    }

    $ssl ||= ${*$self}{'_SSL_object'};

    $SSL_ERROR = undef;
    my $timeout = exists $args->{Timeout}
	? $args->{Timeout}
	: ${*$self}{io_socket_timeout}; # from IO::Socket
    if ( defined($timeout) && $timeout>0 && $self->blocking(0) ) {
	$DEBUG>=2 && DEBUG( "set socket to non-blocking to enforce timeout=$timeout" );
	# timeout was given and socket was blocking
	# enforce timeout with now non-blocking socket
    } else {
	# timeout does not apply because invalid or socket non-blocking
	$timeout = undef;
    }

    my $start = defined($timeout) && time();
    for my $dummy (1) {
	#DEBUG( 'calling ssleay::connect' );
	my $rv = Net::SSLeay::connect($ssl);
	$DEBUG>=3 && DEBUG("Net::SSLeay::connect -> $rv" );
	if ( $rv < 0 ) {
	    unless ( $self->_set_rw_error( $ssl,$rv )) {
		$self->error("SSL connect attempt failed with unknown error");
		delete ${*$self}{'_SSL_opening'};
		${*$self}{'_SSL_opened'} = -1;
		$DEBUG>=1 && DEBUG( "fatal SSL error: $SSL_ERROR" );
		return $self->fatal_ssl_error();
	    }

	    $DEBUG>=2 && DEBUG('ssl handshake in progress' );
	    # connect failed because handshake needs to be completed
	    # if socket was non-blocking or no timeout was given return with this error
	    return if ! defined($timeout);

	    # wait until socket is readable or writable
	    my $rv;
	    if ( $timeout>0 ) {
		my $vec = '';
		vec($vec,$self->fileno,1) = 1;
		$DEBUG>=2 && DEBUG( "waiting for fd to become ready: $SSL_ERROR" );
		$rv =
		    $SSL_ERROR == SSL_WANT_READ ? select( $vec,undef,undef,$timeout) :
		    $SSL_ERROR == SSL_WANT_WRITE ? select( undef,$vec,undef,$timeout) :
		    undef;
	    } else {
		$DEBUG>=2 && DEBUG("handshake failed because no more time" );
		$! = ETIMEDOUT
	    }
	    if ( ! $rv ) {
		$DEBUG>=2 && DEBUG("handshake failed because socket did not became ready" );
		# failed because of timeout, return
		$! ||= ETIMEDOUT;
		delete ${*$self}{'_SSL_opening'};
		${*$self}{'_SSL_opened'} = -1;
		$self->blocking(1); # was blocking before
		return
	    }

	    # socket is ready, try non-blocking connect again after recomputing timeout
	    $DEBUG>=2 && DEBUG("socket ready, retrying connect" );
	    my $now = time();
	    $timeout -= $now - $start;
	    $start = $now;
	    redo;

	} elsif ( $rv == 0 ) {
	    delete ${*$self}{'_SSL_opening'};
	    $DEBUG>=2 && DEBUG("connection failed - connect returned 0" );
	    $self->error("SSL connect attempt failed because of handshake problems" );
	    ${*$self}{'_SSL_opened'} = -1;
	    return $self->fatal_ssl_error();
	}
    }

    $DEBUG>=2 && DEBUG('ssl handshake done' );
    # ssl connect successful
    delete ${*$self}{'_SSL_opening'};
    ${*$self}{'_SSL_opened'}=1;
    $self->blocking(1) if defined($timeout); # was blocking before

    $ctx ||= ${*$self}{'_SSL_ctx'};
    if ( $ctx->has_session_cache ) {
	my $arg_hash = ${*$self}{'_SSL_arguments'};
	$arg_hash->{PeerAddr} || $self->_update_peer;
	my ($addr,$port) = ( $arg_hash->{PeerAddr}, $arg_hash->{PeerPort} );
	my $session = $ctx->session_cache( $addr,$port );
	$ctx->session_cache( $addr,$port, Net::SSLeay::get1_session($ssl) ) if !$session;
    }

    tie *{$self}, "IO::Socket::SSL::SSL_HANDLE", $self;

    return $self;
}

# called if PeerAddr is not set in ${*$self}{'_SSL_arguments'}
# this can be the case if start_SSL is called with a normal IO::Socket::INET
# so that PeerAddr|PeerPort are not set from args
sub _update_peer {
    my $self = shift;
    my $arg_hash = ${*$self}{'_SSL_arguments'};
    eval {
	my $sockaddr = getpeername( $self );
	my $af = sockaddr_family($sockaddr);
	if( CAN_IPV6 && $af == AF_INET6 ) {
	    my ($host, $port) = getnameinfo($sockaddr,
		NI_NUMERICHOST | NI_NUMERICSERV);
	    $arg_hash->{PeerAddr} = $host;
	    $arg_hash->{PeerPort} = $port;
	} else {
	    my ($port,$addr) = sockaddr_in( $sockaddr);
	    $arg_hash->{PeerAddr} = inet_ntoa( $addr );
	    $arg_hash->{PeerPort} = $port;
	}
    }
}

#Call to accept occurs when a new client connects to a server using
#IO::Socket::SSL
sub accept {
    my $self = shift || return _invalid_object();
    my $class = shift || 'IO::Socket::SSL';

    my $socket = ${*$self}{'_SSL_opening'};
    if ( ! $socket ) {
	# underlying socket not done
	$DEBUG>=2 && DEBUG('no socket yet' );
	$socket = $self->SUPER::accept($class) || return;
	$DEBUG>=2 && DEBUG('accept created normal socket '.$socket );
    }

    $self->accept_SSL($socket) || return;
    $DEBUG>=2 && DEBUG('accept_SSL ok' );

    return wantarray ? ($socket, getpeername($socket) ) : $socket;
}

sub accept_SSL {
    my $self = shift;
    my $socket = ( @_ && UNIVERSAL::isa( $_[0], 'IO::Handle' )) ? shift : $self;
    my $args = @_>1 ? {@_}: $_[0]||{};

    my $ssl;
    if ( ! ${*$self}{'_SSL_opening'} ) {
	$DEBUG>=2 && DEBUG('starting sslifying' );
	${*$self}{'_SSL_opening'} = $socket;
	my $arg_hash = ${*$self}{'_SSL_arguments'};
	${*$socket}{'_SSL_arguments'} = { %$arg_hash, SSL_server => 0 };
	my $ctx = ${*$socket}{'_SSL_ctx'} = ${*$self}{'_SSL_ctx'};

	my $fileno = ${*$socket}{'_SSL_fileno'} = fileno($socket);
	return $socket->error("Socket has no fileno") unless (defined $fileno);

	$ssl = ${*$socket}{'_SSL_object'} = Net::SSLeay::new($ctx->{context})
	    || return $socket->error("SSL structure creation failed");
	$CREATED_IN_THIS_THREAD{$ssl} = 1;

	Net::SSLeay::set_fd($ssl, $fileno)
	    || return $socket->error("SSL filehandle association failed");

	if ( my $cl = $arg_hash->{SSL_cipher_list} ) {
	    Net::SSLeay::set_cipher_list($ssl, $cl )
		|| return $socket->error("Failed to set SSL cipher list");
	}
    }

    $ssl ||= ${*$socket}{'_SSL_object'};

    $SSL_ERROR = undef;
    #$DEBUG>=2 && DEBUG('calling ssleay::accept' );

    my $timeout = exists $args->{Timeout}
	? $args->{Timeout}
	: ${*$self}{io_socket_timeout}; # from IO::Socket
    if ( defined($timeout) && $timeout>0 && $socket->blocking(0) ) {
	# timeout was given and socket was blocking
	# enforce timeout with now non-blocking socket
    } else {
	# timeout does not apply because invalid or socket non-blocking
	$timeout = undef;
    }

    my $start = defined($timeout) && time();
    for my $dummy (1) {
	my $rv = Net::SSLeay::accept($ssl);
	$DEBUG>=3 && DEBUG( "Net::SSLeay::accept -> $rv" );
	if ( $rv < 0 ) {
	    unless ( $socket->_set_rw_error( $ssl,$rv )) {
		$socket->error("SSL accept attempt failed with unknown error");
		delete ${*$self}{'_SSL_opening'};
		${*$socket}{'_SSL_opened'} = -1;
		return $socket->fatal_ssl_error();
	    }

	    # accept failed because handshake needs to be completed
	    # if socket was non-blocking or no timeout was given return with this error
	    return if ! defined($timeout);

	    # wait until socket is readable or writable
	    my $rv;
	    if ( $timeout>0 ) {
		my $vec = '';
		vec($vec,$socket->fileno,1) = 1;
		$rv =
		    $SSL_ERROR == SSL_WANT_READ ? select( $vec,undef,undef,$timeout) :
		    $SSL_ERROR == SSL_WANT_WRITE ? select( undef,$vec,undef,$timeout) :
		    undef;
	    } else {
		$! = ETIMEDOUT
	    }
	    if ( ! $rv ) {
		# failed because of timeout, return
		$! ||= ETIMEDOUT;
		delete ${*$self}{'_SSL_opening'};
		${*$socket}{'_SSL_opened'} = -1;
		$socket->blocking(1); # was blocking before
		return
	    }

	    # socket is ready, try non-blocking accept again after recomputing timeout
	    my $now = time();
	    $timeout -= $now - $start;
	    $start = $now;
	    redo;

	} elsif ( $rv == 0 ) {
	    $socket->error("SSL connect accept failed because of handshake problems" );
	    delete ${*$self}{'_SSL_opening'};
	    ${*$socket}{'_SSL_opened'} = -1;
	    return $socket->fatal_ssl_error();
	}
    }

    $DEBUG>=2 && DEBUG('handshake done, socket ready' );
    # socket opened
    delete ${*$self}{'_SSL_opening'};
    ${*$socket}{'_SSL_opened'} = 1;
    $socket->blocking(1) if defined($timeout); # was blocking before

    tie *{$socket}, "IO::Socket::SSL::SSL_HANDLE", $socket;

    return $socket;
}


####### I/O subroutines ########################

sub generic_read {
    my ($self, $read_func, undef, $length, $offset) = @_;
    my $ssl = $self->_get_ssl_object || return;
    my $buffer=\$_[2];

    $SSL_ERROR = undef;
    my $data = $read_func->($ssl, $length);
    if ( !defined($data)) {
	$self->_set_rw_error( $ssl,-1 ) || $self->error("SSL read error");
	return;
    }

    $length = length($data);
    $$buffer = '' if !defined $$buffer;
    $offset ||= 0;
    if ($offset>length($$buffer)) {
	$$buffer.="\0" x ($offset-length($$buffer));  #mimic behavior of read
    }

    substr($$buffer, $offset, length($$buffer), $data);
    return $length;
}

sub read {
    my $self = shift;
    return $self->generic_read(
	$self->blocking ? \&Net::SSLeay::ssl_read_all : \&Net::SSLeay::read,
	@_
    );
}

# contrary to the behavior of read sysread can read partial data
sub sysread {
    my $self = shift;
    return $self->generic_read( \&Net::SSLeay::read, @_ );
}

sub peek {
    my $self = shift;
    return $self->generic_read(\&Net::SSLeay::peek, @_);
}


sub generic_write {
    my ($self, $write_all, undef, $length, $offset) = @_;

    my $ssl = $self->_get_ssl_object || return;
    my $buffer = \$_[2];

    my $buf_len = length($$buffer);
    $length ||= $buf_len;
    $offset ||= 0;
    return $self->error("Invalid offset for SSL write") if ($offset>$buf_len);
    return 0 if ($offset == $buf_len);

    $SSL_ERROR = undef;
    my $written;
    if ( $write_all ) {
	my $data = $length < $buf_len-$offset ? substr($$buffer, $offset, $length) : $$buffer;
	($written, my $errs) = Net::SSLeay::ssl_write_all($ssl, $data);
	# ssl_write_all returns number of bytes written
	$written = undef if ! $written && $errs;
    } else {
	$written = Net::SSLeay::write_partial( $ssl,$offset,$length,$$buffer );
	# write_partial does SSL_write which returns -1 on error
	$written = undef if $written < 0;
    }
    if ( !defined($written) ) {
	$self->_set_rw_error( $ssl,-1 )
	    || $self->error("SSL write error");
	return;
    }

    return $written;
}

# if socket is blocking write() should return only on error or
# if all data are written
sub write {
    my $self = shift;
    return $self->generic_write( scalar($self->blocking),@_ );
}

# contrary to write syswrite() returns already if only
# a part of the data is written
sub syswrite {
    my $self = shift;
    return $self->generic_write( 0,@_ );
}

sub print {
    my $self = shift;
    my $string = join(($, or ''), @_, ($\ or ''));
    return $self->write( $string );
}

sub printf {
    my ($self,$format) = (shift,shift);
    return $self->write(sprintf($format, @_));
}

sub getc {
    my ($self, $buffer) = (shift, undef);
    return $buffer if $self->read($buffer, 1, 0);
}

sub readline {
    my $self = shift;

    if ( not defined $/ or wantarray) {
	# read all and split

	my $buf = '';
	while (1) {
	    my $rv = $self->sysread($buf,2**16,length($buf));
	    if ( ! defined $rv ) {
		next if $!{EINTR};                     # retry
		last if $!{EAGAIN} || $!{EWOULDBLOCK}; # use everything so far
		return;                                # return error
	    } elsif ( ! $rv ) {
		last
	    }
	}

	if ( ! defined $/ ) {
	    return $buf
	} elsif ( ref($/)) {
	    my $size = ${$/};
	    die "bad value in ref \$/: $size" unless $size>0;
	    return $buf=~m{\G(.{1,$size})}g;
	} elsif ( $/ eq '' ) {
	    return $buf =~m{\G(.*\n\n+|.+)}g;
	} else {
	    return $buf =~m{\G(.*$/|.+)}g;
	}
    }

    # read only one line
    if ( ref($/) ) {
	my $size = ${$/};
	# read record of $size bytes
	die "bad value in ref \$/: $size" unless $size>0;
	my $buf = '';
	while ( $size>length($buf)) {
	    my $rv = $self->sysread($buf,$size-length($buf),length($buf));
	    if ( ! defined $rv ) {
		next if $!{EINTR};                     # retry
		last if $!{EAGAIN} || $!{EWOULDBLOCK}; # use everything so far
		return;                                # return error
	    } elsif ( ! $rv ) {
		last
	    }
	}
	return $buf;
    }

    my ($delim0,$delim1) = $/ eq '' ? ("\n\n","\n"):($/,'');

    # find first occurrence of $delim0 followed by as much as possible $delim1
    my $buf = '';
    my $eod = 0;  # pointer into $buf after $delim0 $delim1*
    my $ssl = $self->_get_ssl_object or return;
    while (1) {

	# wait until we have more data or eof
	my $poke = Net::SSLeay::peek($ssl,1);
	if ( ! defined $poke or $poke eq '' ) {
	    next if $!{EINTR};
	}

	my $skip = 0;

	# peek into available data w/o reading
	my $pending = Net::SSLeay::pending($ssl);
	if ( $pending and 
	    ( my $pb = Net::SSLeay::peek( $ssl,$pending )) ne '' ) {
	    $buf .= $pb
	} else {
	    return $buf eq '' ? ():$buf;
	};
	if ( !$eod ) {
	    my $pos = index( $buf,$delim0 );
	    if ( $pos<0 ) {
		$skip = $pending
	    } else {
		$eod = $pos + length($delim0); # pos after delim0
	    }
	}

	if ( $eod ) {
	    if ( $delim1 ne '' ) {
		# delim0 found, check for as much delim1 as possible
		while ( index( $buf,$delim1,$eod ) == $eod ) {
		    $eod+= length($delim1);
		}
	    }
	    $skip = $pending - ( length($buf) - $eod );
	}

	# remove data from $self which I already have in buf
	while ( $skip>0 ) {
	    if ($self->sysread(my $p,$skip,0)) {
		$skip -= length($p);
		next;
	    }
	    $!{EINTR} or last;
	}

	if ( $eod and ( $delim1 eq '' or $eod < length($buf))) {
	    # delim0 found and there can be no more delim1 pending
	    last
	}
    }
    return substr($buf,0,$eod);
}

sub close {
    my $self = shift || return _invalid_object();
    my $close_args = (ref($_[0]) eq 'HASH') ? $_[0] : {@_};

    return if ! $self->stop_SSL(
	SSL_fast_shutdown => 1,
	%$close_args,
	_SSL_ioclass_downgrade => 0,
    );

    if ( ! $close_args->{_SSL_in_DESTROY} ) {
	untie( *$self );
	undef ${*$self}{_SSL_fileno};
	return $self->SUPER::close;
    }
    return 1;
}

sub stop_SSL {
    my $self = shift || return _invalid_object();
    my $stop_args = (ref($_[0]) eq 'HASH') ? $_[0] : {@_};
    $stop_args->{SSL_no_shutdown} = 1 if ! ${*$self}{_SSL_opened};

    if (my $ssl = ${*$self}{'_SSL_object'}) {
	my $shutdown_done;
	if ( $stop_args->{SSL_no_shutdown} ) {
	    $shutdown_done = 1;
	} else {
	    my $fast = $stop_args->{SSL_fast_shutdown};
	    my $status = Net::SSLeay::get_shutdown($ssl);
	    if ( $fast && $status != 0) {
		# shutdown done, either status has  
		# SSL_SENT_SHUTDOWN or SSL_RECEIVED_SHUTDOWN or both,
		# so the handshake is at least in process
		$shutdown_done = 1;
	    } elsif ( ( $status & SSL_SENT_SHUTDOWN ) == 0 ) {
		# need to initiate/continue shutdown
		local $SIG{PIPE} = 'IGNORE';
		for my $try (1,2 ) {
		    my $rv = Net::SSLeay::shutdown($ssl);
		    if ( $rv < 0 ) {
			# non-blocking socket?
			$self->_set_rw_error( $ssl,$rv );
			# need to try again
			return;
		    } elsif ( $rv
			|| ( $rv == 0 && $fast )) {
			# shutdown finished
			$shutdown_done = 1;
			last;
		    } else {
			# shutdown partly initiated (e.g. one direction)
			# call again
		    }
		}
	    } elsif ( $status & SSL_RECEIVED_SHUTDOWN ) {
		# SSL_SENT_SHUTDOWN is done already (previous if-case)
		# and because SSL_RECEIVED_SHUTDOWN is done also we
		# consider the shutdown done
		$shutdown_done = 1;
	    }
	}

	return if ! $shutdown_done;
	Net::SSLeay::free($ssl);
	delete ${*$self}{_SSL_object};
    }

    if ($stop_args->{'SSL_ctx_free'}) {
	my $ctx = delete ${*$self}{'_SSL_ctx'};
	$ctx && $ctx->DESTROY();
    }

    if (my $cert = delete ${*$self}{'_SSL_certificate'}) {
	Net::SSLeay::X509_free($cert);
    }

    ${*$self}{'_SSL_opened'} = 0;

    if ( ! $stop_args->{_SSL_in_DESTROY} ) {

	my $downgrade = $stop_args->{_SSL_ioclass_downgrade};
	if ( $downgrade || ! defined $downgrade ) {
	    # rebless to original class from start_SSL
	    if ( my $orig_class = delete ${*$self}{'_SSL_ioclass_upgraded'} ) {
		bless $self,$orig_class;
		untie(*$self);
		# FIXME: if original class was tied too we need to restore the tie
	    }
	    # remove all _SSL related from *$self
	    my @sslkeys = grep { m{^_?SSL_} } keys %{*$self};
	    delete @{*$self}{@sslkeys} if @sslkeys;
	}
    }
    return 1;
}


sub fileno {
    my $self = shift;
    my $fn = ${*$self}{'_SSL_fileno'};
	return defined($fn) ? $fn : $self->SUPER::fileno();
}


####### IO::Socket::SSL specific functions #######
# _get_ssl_object is for internal use ONLY!
sub _get_ssl_object {
    my $self = shift;
    my $ssl = ${*$self}{'_SSL_object'};
    return IO::Socket::SSL->error("Undefined SSL object") unless($ssl);
    return $ssl;
}

# _get_ctx_object is for internal use ONLY!
sub _get_ctx_object {
    my $self = shift;
    my $ctx_object = ${*$self}{_SSL_ctx};
    return $ctx_object && $ctx_object->{context};
}

# default error for undefined arguments
sub _invalid_object {
    return IO::Socket::SSL->error("Undefined IO::Socket::SSL object");
}


sub pending {
    my $ssl = shift()->_get_ssl_object || return;
    return Net::SSLeay::pending($ssl);
}

sub start_SSL {
    my ($class,$socket) = (shift,shift);
    return $class->error("Not a socket") unless(ref($socket));
    my $arg_hash = (ref($_[0]) eq 'HASH') ? $_[0] : {@_};
    my %to = exists $arg_hash->{Timeout} ? ( Timeout => delete $arg_hash->{Timeout} ) :();
    my $original_class = ref($socket);
    my $original_fileno = (UNIVERSAL::can($socket, "fileno"))
	? $socket->fileno : CORE::fileno($socket);
    return $class->error("Socket has no fileno") unless defined $original_fileno;

    bless $socket, $class;
    $socket->configure_SSL($arg_hash) or bless($socket, $original_class) && return;

    ${*$socket}{'_SSL_fileno'} = $original_fileno;
    ${*$socket}{'_SSL_ioclass_upgraded'} = $original_class;

    my $start_handshake = $arg_hash->{SSL_startHandshake};
    if ( ! defined($start_handshake) || $start_handshake ) {
	# if we have no callback force blocking mode
	$DEBUG>=2 && DEBUG( "start handshake" );
	my $blocking = $socket->blocking(1);
	my $result = ${*$socket}{'_SSL_arguments'}{SSL_server}
	    ? $socket->accept_SSL(%to)
	    : $socket->connect_SSL(%to);
	$socket->blocking(0) if !$blocking;
	return $result ? $socket : (bless($socket, $original_class) && ());
    } else {
	$DEBUG>=2 && DEBUG( "dont start handshake: $socket" );
	return $socket; # just return upgraded socket
    }

}

sub new_from_fd {
    my ($class, $fd) = (shift,shift);
    # Check for accidental inclusion of MODE in the argument list
    if (length($_[0]) < 4) {
	(my $mode = $_[0]) =~ tr/+<>//d;
	shift unless length($mode);
    }
    my $handle = $ISA[0]->new_from_fd($fd, '+<')
	|| return($class->error("Could not create socket from file descriptor."));

    # Annoying workaround for Perl 5.6.1 and below:
    $handle = $ISA[0]->new_from_fd($handle, '+<');

    return $class->start_SSL($handle, @_);
}


sub dump_peer_certificate {
    my $ssl = shift()->_get_ssl_object || return;
    return Net::SSLeay::dump_peer_certificate($ssl);
}

{
    my %dispatcher = (
	issuer =>  sub { Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_issuer_name( shift )) },
	subject => sub { Net::SSLeay::X509_NAME_oneline( Net::SSLeay::X509_get_subject_name( shift )) },
    );
    if ( $Net::SSLeay::VERSION >= 1.30 ) {
	# I think X509_NAME_get_text_by_NID got added in 1.30
	$dispatcher{commonName} = sub {
	    my $cn = Net::SSLeay::X509_NAME_get_text_by_NID(
		Net::SSLeay::X509_get_subject_name( shift ), NID_CommonName);
	    $cn =~s{\0$}{}; # work around Bug in Net::SSLeay <1.33
	    $cn;
	}
    } else {
	$dispatcher{commonName} = sub {
	    croak "you need at least Net::SSLeay version 1.30 for getting commonName"
	}
    }

    if ( $Net::SSLeay::VERSION >= 1.33 ) {
	# X509_get_subjectAltNames did not really work before
	$dispatcher{subjectAltNames} = sub { Net::SSLeay::X509_get_subjectAltNames( shift ) };
    } else {
	$dispatcher{subjectAltNames} = sub {
	    croak "you need at least Net::SSLeay version 1.33 for getting subjectAltNames"
	};
    }

    # alternative names
    $dispatcher{authority} = $dispatcher{issuer};
    $dispatcher{owner}     = $dispatcher{subject};
    $dispatcher{cn}        = $dispatcher{commonName};

    sub peer_certificate {
	my ($self, $field) = @_;
	my $ssl = $self->_get_ssl_object or return;

	my $cert = ${*$self}{_SSL_certificate}
	    ||= Net::SSLeay::get_peer_certificate($ssl)
	    or return $self->error("Could not retrieve peer certificate");

	if ($field) {
	    my $sub = $dispatcher{$field} or croak
		"invalid argument for peer_certificate, valid are: ".join( " ",keys %dispatcher ).
		"\nMaybe you need to upgrade your Net::SSLeay";
	    return $sub->($cert);
	} else {
	    return $cert
	}
    }

    # known schemes, possible attributes are:
    #  - wildcards_in_alt (0, 'leftmost', 'anywhere')
    #  - wildcards_in_cn (0, 'leftmost', 'anywhere')
    #  - check_cn (0, 'always', 'when_only')

    my %scheme = (
	# rfc 4513
	ldap => {
	    wildcards_in_cn  => 0,
	    wildcards_in_alt => 'leftmost',
	    check_cn         => 'always',
	},
	# rfc 2818
	http => {
	    wildcards_in_cn  => 'anywhere',
	    wildcards_in_alt => 'anywhere',
	    check_cn         => 'when_only',
	},
	# rfc 3207
	# This is just a dumb guess
	# RFC3207 itself just says, that the client should expect the
	# domain name of the server in the certificate. It doesn't say
	# anything about wildcards, so I forbid them. It doesn't say
	# anything about alt names, but other documents show, that alt
	# names should be possible. The check_cn value again is a guess.
	# Fix the spec!
	smtp => {
	    wildcards_in_cn  => 0,
	    wildcards_in_alt => 0,
	    check_cn         => 'always'
	},
	none => {}, # do not check
    );

    $scheme{www}  = $scheme{http}; # alias
    $scheme{xmpp} = $scheme{http}; # rfc 3920
    $scheme{pop3} = $scheme{ldap}; # rfc 2595
    $scheme{imap} = $scheme{ldap}; # rfc 2595
    $scheme{acap} = $scheme{ldap}; # rfc 2595
    $scheme{nntp} = $scheme{ldap}; # rfc 4642
    $scheme{ftp}  = $scheme{http}; # rfc 4217

    # function to verify the hostname
    #
    # as every application protocol has its own rules to do this
    # we provide some default rules as well as a user-defined
    # callback

    sub verify_hostname_of_cert {
	my $identity = shift;
	my $cert = shift;
	my $scheme = shift || 'none';
	if ( ! ref($scheme) ) {
	    $DEBUG>=3 && DEBUG( "scheme=$scheme cert=$cert" );
	    $scheme = $scheme{$scheme} or croak "scheme $scheme not defined";
	}

	return 1 if ! %$scheme; # 'none'

	# get data from certificate
	my $commonName = $dispatcher{cn}->($cert);
	my @altNames = $dispatcher{subjectAltNames}->($cert);
	$DEBUG>=3 && DEBUG("identity=$identity cn=$commonName alt=@altNames" );

	if ( my $sub = $scheme->{callback} ) {
	    # use custom callback
	    return $sub->($identity,$commonName,@altNames);
	}

	# is the given hostname an IP address? Then we have to convert to network byte order [RFC791][RFC2460]

	my $ipn;
	if ( CAN_IPV6 and $identity =~m{:} ) {
	    # no IPv4 or hostname have ':'  in it, try IPv6.
	    $ipn = inet_pton(AF_INET6,$identity) 
		or croak "'$identity' is not IPv6, but neither IPv4 nor hostname";
	} elsif ( $identity =~m{^\d+\.\d+\.\d+\.\d+$} ) {
	     # definitely no hostname, try IPv4
	    $ipn = inet_aton( $identity ) or croak "'$identity' is not IPv4, but neither IPv6 nor hostname";
	} else {
	    # assume hostname, check for umlauts etc
	    if ( $identity =~m{[^a-zA-Z0-9_.\-]} ) {
		$identity =~m{\0} and croak("name '$identity' has \\0 byte");
		$identity = idn_to_ascii($identity) or
		    croak "Warning: Given name '$identity' could not be converted to IDNA!";
	    }
	}

	# do the actual verification
	my $check_name = sub {
	    my ($name,$identity,$wtyp) = @_;
	    $wtyp ||= '';
	    my $pattern;
	    ### IMPORTANT!
	    # we accept only a single wildcard and only for a single part of the FQDN
	    # e.g *.example.org does match www.example.org but not bla.www.example.org
	    # The RFCs are in this regard unspecific but we don't want to have to
	    # deal with certificates like *.com, *.co.uk or even *
	    # see also http://nils.toedtmann.net/pub/subjectAltName.txt
	    if ( $wtyp eq 'anywhere' and $name =~m{^([a-zA-Z0-9_\-]*)\*(.+)} ) {
		$pattern = qr{^\Q$1\E[a-zA-Z0-9_\-]*\Q$2\E$}i;
	    } elsif ( $wtyp eq 'leftmost' and $name =~m{^\*(\..+)$} ) {
		$pattern = qr{^[a-zA-Z0-9_\-]*\Q$1\E$}i;
	    } else {
		$pattern = qr{^\Q$name\E$}i;
	    }
	    return $identity =~ $pattern;
	};

	my $alt_dnsNames = 0;
	while (@altNames) {
	    my ($type, $name) = splice (@altNames, 0, 2);
	    if ( $ipn and $type == GEN_IPADD ) {
		# exact match needed for IP
		# $name is already packed format (inet_xton)
		return 1 if $ipn eq $name;

	    } elsif ( ! $ipn and $type == GEN_DNS ) {
		$name =~s/\s+$//; $name =~s/^\s+//;
		$alt_dnsNames++;
		$check_name->($name,$identity,$scheme->{wildcards_in_alt})
		    and return 1;
	    }
	}

	if ( ! $ipn and (
	    $scheme->{check_cn} eq 'always' or
	    $scheme->{check_cn} eq 'when_only' and !$alt_dnsNames)) {
	    $check_name->($commonName,$identity,$scheme->{wildcards_in_cn})
		and return 1;
	}

	return 0; # no match
    }
}

sub verify_hostname {
    my $self = shift;
    my $host = shift;
    my $cert = $self->peer_certificate;
    return verify_hostname_of_cert( $host,$cert,@_ );
}


sub get_servername {
    my $self = shift;
    return ${*$self}{_SSL_servername} ||= do {
	my $ssl = $self->_get_ssl_object or return;
	Net::SSLeay::get_servername($ssl);
    };
}

sub get_cipher {
    my $ssl = shift()->_get_ssl_object || return;
    return Net::SSLeay::get_cipher($ssl);
}

sub errstr {
    my $self = shift;
    return ((ref($self) ? ${*$self}{'_SSL_last_err'} : $SSL_ERROR) or '');
}

sub fatal_ssl_error {
    my $self = shift;
    my $error_trap = ${*$self}{'_SSL_arguments'}->{'SSL_error_trap'};
    $@ = $self->errstr;
    if (defined $error_trap and ref($error_trap) eq 'CODE') {
	$error_trap->($self, $self->errstr()."\n".$self->get_ssleay_error());
    } elsif ( ${*$self}{'_SSL_ioclass_upgraded'} ) {
	# downgrade only
	$self->stop_SSL;
    } else {
	# kill socket
	$self->close
    }
    return;
}

sub get_ssleay_error {
    #Net::SSLeay will print out the errors itself unless we explicitly
    #undefine $Net::SSLeay::trace while running print_errs()
    local $Net::SSLeay::trace;
    return Net::SSLeay::print_errs('SSL error: ') || '';
}

sub error {
    my ($self, $error, $destroy_socket) = @_;
    my @err;
    while ( my $err = Net::SSLeay::ERR_get_error()) {
	push @err, Net::SSLeay::ERR_error_string($err);
	$DEBUG>=2 && DEBUG( $error."\n".$self->get_ssleay_error());
    }
    # if no new error occurred report last again
    if ( ! @err and my $err = 
	ref($self) ? ${*$self}{'_SSL_last_err'} : $SSL_ERROR ) {
	push @err,$err;
    }
    $error .= ' '.join(' ',@err) if @err;
    if ($error) {
	$SSL_ERROR = dualvar( -1, $error );
	${*$self}{'_SSL_last_err'} = $SSL_ERROR if (ref($self));
    }
    return;
}

sub can_client_sni { return $can_client_sni }
sub can_server_sni { return $can_server_sni }
sub can_npn        { return $can_npn }

sub DESTROY {
    my $self = shift or return;
    my $ssl = ${*$self}{_SSL_object} or return;
    if ($CREATED_IN_THIS_THREAD{$ssl}) {
	$self->close(_SSL_in_DESTROY => 1, SSL_no_shutdown => 1)
	    if ${*$self}{'_SSL_opened'};
	delete(${*$self}{'_SSL_ctx'});
    }
}


#######Extra Backwards Compatibility Functionality#######
sub socket_to_SSL { IO::Socket::SSL->start_SSL(@_); }
sub socketToSSL { IO::Socket::SSL->start_SSL(@_); }
sub kill_socket { shift->close }

sub issuer_name { return(shift()->peer_certificate("issuer")) }
sub subject_name { return(shift()->peer_certificate("subject")) }
sub get_peer_certificate { return shift() }

sub context_init {
    return($GLOBAL_SSL_ARGS = (ref($_[0]) eq 'HASH') ? $_[0] : {@_});
}

sub set_default_context {
    $GLOBAL_SSL_ARGS->{'SSL_reuse_ctx'} = shift;
}

sub set_default_session_cache {
    $GLOBAL_SSL_ARGS->{SSL_session_cache} = shift;
}

sub set_defaults {
    my %args = @_;
    while ( my ($k,$v) = each %args ) {
	$k =~s{^(SSL_)?}{SSL_};
	$GLOBAL_SSL_ARGS->{$k} = $v;
    }
}
{ # deprecated API
    no warnings;
    *set_ctx_defaults = \&set_defaults; 
}

sub next_proto_negotiated {
    my $self = shift;
    return $self->error("NPN not supported in Net::SSLeay") if ! $can_npn;
    my $ssl = $self->_get_ssl_object || return;
    return Net::SSLeay::P_next_proto_negotiated($ssl);
}

sub opened {
    my $self = shift;
    return IO::Handle::opened($self) && ${*$self}{'_SSL_opened'};
}

sub opening {
    my $self = shift;
    return ${*$self}{'_SSL_opening'};
}

sub want_read  { shift->errstr == SSL_WANT_READ }
sub want_write { shift->errstr == SSL_WANT_WRITE }


#Redundant IO::Handle functionality
sub getline { return(scalar shift->readline()) }
sub getlines {
    return(shift->readline()) if wantarray();
    croak("Use of getlines() not allowed in scalar context");
}

#Useless IO::Handle functionality
sub truncate { croak("Use of truncate() not allowed with SSL") }
sub stat     { croak("Use of stat() not allowed with SSL" ) }
sub setbuf   { croak("Use of setbuf() not allowed with SSL" ) }
sub setvbuf  { croak("Use of setvbuf() not allowed with SSL" ) }
sub fdopen   { croak("Use of fdopen() not allowed with SSL" ) }

#Unsupported socket functionality
sub ungetc { croak("Use of ungetc() not implemented in IO::Socket::SSL") }
sub send   { croak("Use of send() not implemented in IO::Socket::SSL; use print/printf/syswrite instead") }
sub recv   { croak("Use of recv() not implemented in IO::Socket::SSL; use read/sysread instead") }

package IO::Socket::SSL::SSL_HANDLE;
use strict;
use vars qw($HAVE_WEAKREF);
use Errno 'EBADF';

BEGIN {
    local ($@, $SIG{__DIE__});

    #Use Scalar::Util or WeakRef if possible:
    eval "use Scalar::Util qw(weaken isweak); 1" or
	eval "use WeakRef";
    $HAVE_WEAKREF = $@ ? 0 : 1;
}


sub TIEHANDLE {
    my ($class, $handle) = @_;
    weaken($handle) if $HAVE_WEAKREF;
    bless \$handle, $class;
}

sub READ     { ${shift()}->sysread(@_) }
sub READLINE { ${shift()}->readline(@_) }
sub GETC     { ${shift()}->getc(@_) }

sub PRINT    { ${shift()}->print(@_) }
sub PRINTF   { ${shift()}->printf(@_) }
sub WRITE    { ${shift()}->syswrite(@_) }

sub FILENO   { ${shift()}->fileno(@_) }

sub TELL     { $! = EBADF; return -1 }
sub BINMODE  { return 0 }  # not perfect, but better than not implementing the method

sub CLOSE {                          #<---- Do not change this function!
    my $ssl = ${$_[0]};
    local @_;
    $ssl->close();
}


package IO::Socket::SSL::SSL_Context;
use Carp;
use strict;

my %CTX_CREATED_IN_THIS_THREAD;
*DEBUG = *IO::Socket::SSL::DEBUG;

# should be better taken from Net::SSLeay, but they are not (yet) defined there
use constant SSL_MODE_ENABLE_PARTIAL_WRITE => 1;
use constant SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER => 2;


# Note that the final object will actually be a reference to the scalar
# (C-style pointer) returned by Net::SSLeay::CTX_*_new() so that
# it can be blessed.
sub new {
    my $class = shift;
    #DEBUG( "$class @_" );
    my $arg_hash = (ref($_[0]) eq 'HASH') ? $_[0] : {@_};

    my $ctx_object = $arg_hash->{'SSL_reuse_ctx'};
    if ($ctx_object) {
	return $ctx_object if ($ctx_object->isa('IO::Socket::SSL::SSL_Context') and
	    $ctx_object->{context});

	# The following "double entendre" applies only if someone passed
	# in an IO::Socket::SSL object instead of an actual context.
	return $ctx_object if ($ctx_object = ${*$ctx_object}{'_SSL_ctx'});
    }

    my $ver='';
    my $disable_ver = 0;
    for (split(/\s*:\s*/,$arg_hash->{SSL_version})) {
	m{^(!?)(?:(SSL(?:v2|v3|v23|v2/3))|(TLSv1(?:_?[12])?))$}i
	or croak("invalid SSL_version specified");
	my $not = $1;
	( my $v = lc($2||$3) ) =~s{^(...)}{\U$1};
	if ( $not ) {
	    $disable_ver |= $SSL_OP_NO{$v};
	} else {
	    croak("cannot set multiple SSL protocols in SSL_version")
		if $ver && $v ne $ver;
	    $ver = $v;
	    $ver =~s{/}{}; # interpret SSLv2/3 as SSLv23
	    $ver =~s{(TLSv1)(\d)}{$1\_$2}; # TLSv1_1
	}
    }

    my $ctx_new_sub =  UNIVERSAL::can( 'Net::SSLeay',
	$ver eq 'SSLv2'   ? 'CTX_v2_new' :
	$ver eq 'SSLv3'   ? 'CTX_v3_new' :
	$ver eq 'TLSv1'   ? 'CTX_tlsv1_new' :
	$ver eq 'TLSv1_1' ? 'CTX_tlsv1_1_new' :
	$ver eq 'TLSv1_2' ? 'CTX_tlsv1_2_new' :
	'CTX_new'
    ) or return IO::Socket::SSL->error("SSL Version $ver not supported");
    my $ctx = $ctx_new_sub->() or return 
	IO::Socket::SSL->error("SSL Context init failed");

    Net::SSLeay::CTX_set_options($ctx, Net::SSLeay::OP_ALL() | $disable_ver );
    if ( $arg_hash->{SSL_honor_cipher_order} ) {
	Net::SSLeay::CTX_set_options($ctx, 0x00400000);
    }

    # if we don't set session_id_context if client certificate is expected
    # client session caching will fail
    # if user does not provide explicit id just use the stringification
    # of the context
    if ( my $id = $arg_hash->{SSL_session_id_context} 
	|| ( $arg_hash->{SSL_verify_mode} & 0x01 ) && "$ctx" ) {
	Net::SSLeay::CTX_set_session_id_context($ctx,$id,length($id));
    }

    # SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER makes syswrite return if at least one
    # buffer was written and not block for the rest
    # SSL_MODE_ENABLE_PARTIAL_WRITE can be necessary for non-blocking because we
    # cannot guarantee, that the location of the buffer stays constant
    Net::SSLeay::CTX_set_mode( $ctx,
	SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER|SSL_MODE_ENABLE_PARTIAL_WRITE);

    if ( my $proto_list = $arg_hash->{SSL_npn_protocols} ) {
	return IO::Socket::SSL->error("NPN not supported in Net::SSLeay")
	    if ! $can_npn;
	if($arg_hash->{SSL_server}) {
	    # on server side SSL_npn_protocols means a list of advertised protocols
	    Net::SSLeay::CTX_set_next_protos_advertised_cb($ctx, $proto_list);
	} else {
	    # on client side SSL_npn_protocols means a list of preferred protocols
	    # negotiation algorithm used is "as-openssl-implements-it"
	    Net::SSLeay::CTX_set_next_proto_select_cb($ctx, $proto_list);
	}
    }

    my $verify_mode = $arg_hash->{SSL_verify_mode};
    if ( $verify_mode != Net::SSLeay::VERIFY_NONE() and
	( defined $arg_hash->{SSL_ca_file} || defined $arg_hash->{SSL_ca_path}) and
	! Net::SSLeay::CTX_load_verify_locations(
	    $ctx, $arg_hash->{SSL_ca_file} || '',$arg_hash->{SSL_ca_path} || '') ) {
	return IO::Socket::SSL->error("Invalid certificate authority locations");
    }

    if ($arg_hash->{'SSL_check_crl'}) {
	Net::SSLeay::X509_STORE_set_flags(
	    Net::SSLeay::CTX_get_cert_store($ctx),
	    Net::SSLeay::X509_V_FLAG_CRL_CHECK()
	);
	if ($arg_hash->{'SSL_crl_file'}) {
	    my $bio = Net::SSLeay::BIO_new_file($arg_hash->{'SSL_crl_file'}, 'r');
	    my $crl = Net::SSLeay::PEM_read_bio_X509_CRL($bio);
	    if ( $crl ) {
		Net::SSLeay::X509_STORE_add_crl(Net::SSLeay::CTX_get_cert_store($ctx), $crl);
	    } else {
		return IO::Socket::SSL->error("Invalid certificate revocation list");
	    }
	}
    }

    if ($arg_hash->{'SSL_server'} || $arg_hash->{'SSL_use_cert'}) {
	my $filetype = Net::SSLeay::FILETYPE_PEM();

	if ($arg_hash->{'SSL_passwd_cb'}) {
	    Net::SSLeay::CTX_set_default_passwd_cb($ctx, $arg_hash->{'SSL_passwd_cb'});
	}

	my %sni;
	for my $opt (qw(SSL_key SSL_key_file SSL_cert SSL_cert_file)) {
	    my $val  = $arg_hash->{$opt} or next;
	    if ( ref($val) eq 'HASH' ) {
		# SNI
		while ( my ($host,$v) = each %$val ) {
		    $sni{lc($host)}{$opt} = $v;
		}
	    } else {
		$sni{''}{$opt} = $val;
	    }
	}

	$sni{''}{ctx} = $ctx if exists $sni{''}; # default if no SNI
	for my $sni (values %sni) {
	    # we need a new context for each server
	    my $snictx = $sni->{ctx} ||= $ctx_new_sub->() or return 
		IO::Socket::SSL->error("SSL Context init failed");

	    if ( my $pkey = $sni->{SSL_key} ) {
		# binary, e.g. EVP_PKEY*
		Net::SSLeay::CTX_use_PrivateKey($snictx, $pkey)
		    || return IO::Socket::SSL->error("Failed to use Private Key");
	    } elsif ( my $f = $sni->{SSL_key_file} ) {
		Net::SSLeay::CTX_use_PrivateKey_file($snictx, $f, $filetype)
		    || return IO::Socket::SSL->error("Failed to open Private Key");
	    }

	    if ( my $x509 = $sni->{SSL_cert} ) {
		# binary, e.g. X509*
		# we have either a single certificate or a list with
		# a chain of certificates
		my @x509 = ref($x509) eq 'ARRAY' ? @$x509: ($x509);
		my $cert = shift @x509;
		Net::SSLeay::CTX_use_certificate( $snictx,$cert )
		    || return IO::Socket::SSL->error("Failed to use Certificate");
		foreach my $ca (@x509) {
		    Net::SSLeay::CTX_add_extra_chain_cert( $snictx,$ca )
			|| return IO::Socket::SSL->error("Failed to use Certificate");
		}
	    } elsif ( my $f = $sni->{SSL_cert_file} ) {
		Net::SSLeay::CTX_use_certificate_chain_file($snictx, $f)
		    || return IO::Socket::SSL->error("Failed to open Certificate");
	    }
	}

	if ( keys %sni > 1 or ! exists $sni{''} ) {
	    # we definitely want SNI support
	    $can_server_sni or return IO::Socket::SSL->error(
		"Server side SNI not supported for this openssl/Net::SSLeay");
	    $_ = $_->{ctx} for( values %sni);
	    Net::SSLeay::CTX_set_tlsext_servername_callback($ctx, sub {
		my $ssl = shift;
		my $host = Net::SSLeay::get_servername($ssl);
		$host = '' if ! defined $host;
		my $snictx = $sni{lc($host)} || $sni{''} or do {
		    $DEBUG>1 and DEBUG(
			"cannot get context from servername '$host'");
		    return 0;
		};
		$DEBUG>1 and DEBUG("set context from servername $host");
		Net::SSLeay::set_SSL_CTX($ssl,$snictx) if $snictx != $ctx;
		return 1;
	    });
	}

	if ( my $dh = $arg_hash->{SSL_dh} ) {
	    # binary, e.g. DH*
	    Net::SSLeay::CTX_set_tmp_dh( $ctx,$dh )
		|| return IO::Socket::SSL->error( "Failed to set DH from SSL_dh" );
	} elsif ( my $f = $arg_hash->{SSL_dh_file} ) {
	    my $bio = Net::SSLeay::BIO_new_file( $f,'r' )
		|| return IO::Socket::SSL->error( "Failed to open DH file $f" );
	    my $dh = Net::SSLeay::PEM_read_bio_DHparams($bio);
	    Net::SSLeay::BIO_free($bio);
	    $dh || return IO::Socket::SSL->error( "Failed to read PEM for DH from $f - wrong format?" );
	    my $rv = Net::SSLeay::CTX_set_tmp_dh( $ctx,$dh );
	    Net::SSLeay::DH_free( $dh );
	    $rv || return IO::Socket::SSL->error( "Failed to set DH from $f" );
	}

	if ( my $curve = $arg_hash->{SSL_ecdh_curve} ) {
	    return IO::Socket::SSL->error(
		"ECDH curve needs Net::SSLeay>=1.56 and OpenSSL>=1.0")
		if ! defined( &Net::SSLeay::CTX_set_tmp_ecdh );
	    if ( $curve !~ /^\d+$/ ) {
		# name of curve, find NID
		$curve = Net::SSLeay::OBJ_txt2nid($curve) 
		    || return IO::Socket::SSL->error(
		    "cannot find NID for curve name '$curve'");
	    }
	    my $ecdh = Net::SSLeay::EC_KEY_new_by_curve_name($curve) or 
		return IO::Socket::SSL->error(
		"cannot create curve for NID $curve");
	    Net::SSLeay::CTX_set_tmp_ecdh($ctx,$ecdh) or
		return IO::Socket::SSL->error(
		"failed to set ECDH curve context");
	    Net::SSLeay::EC_KEY_free($ecdh);
	}
    }

    my $verify_cb = $arg_hash->{SSL_verify_callback};
    my $verify_callback = $verify_cb && sub {
	my ($ok, $ctx_store) = @_;
	my ($certname,$cert,$error);
	if ($ctx_store) {
	    $cert = Net::SSLeay::X509_STORE_CTX_get_current_cert($ctx_store);
	    $error = Net::SSLeay::X509_STORE_CTX_get_error($ctx_store);
	    $certname = Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_issuer_name($cert)).
		Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert));
	    $error &&= Net::SSLeay::ERR_error_string($error);
	}
	$DEBUG>=3 && DEBUG( "ok=$ok cert=$cert" );
	return $verify_cb->($ok,$ctx_store,$certname,$error,$cert);
    };

    Net::SSLeay::CTX_set_verify($ctx, $verify_mode, $verify_callback);

    if ( my $cb = $arg_hash->{SSL_create_ctx_callback} ) {
	$cb->($ctx);
    }

    $ctx_object = { context => $ctx };
    $ctx_object->{has_verifycb} = 1 if $verify_callback;
    $DEBUG>=3 && DEBUG( "new ctx $ctx" );
    $CTX_CREATED_IN_THIS_THREAD{$ctx} = 1;

    if ( my $cache = $arg_hash->{SSL_session_cache} ) {
	# use predefined cache
	$ctx_object->{session_cache} = $cache
    } elsif ( my $size = $arg_hash->{SSL_session_cache_size}) {
	return IO::Socket::SSL->error("Session caches not supported for Net::SSLeay < v1.26")
	    if $Net::SSLeay::VERSION < 1.26;
	$ctx_object->{session_cache} = IO::Socket::SSL::Session_Cache->new( $size );
    }


    return bless $ctx_object, $class;
}


sub session_cache {
    my $ctx = shift;
    my $cache = $ctx->{'session_cache'} || return;
    my ($addr,$port,$session) = @_;
    $port ||= $addr =~s{:(\w+)$}{} && $1; # host:port
    my $key = "$addr:$port";
    return defined($session)
	? $cache->add_session($key, $session)
	: $cache->get_session($key);
}

sub has_session_cache {
    return defined shift->{session_cache};
}


sub CLONE { %CTX_CREATED_IN_THIS_THREAD = (); }
sub DESTROY {
    my $self = shift;
    if ( my $ctx = $self->{context} ) {
	$DEBUG>=3 && DEBUG("free ctx $ctx open=".join( " ",keys %CTX_CREATED_IN_THIS_THREAD ));
	if ( %CTX_CREATED_IN_THIS_THREAD and
	    delete $CTX_CREATED_IN_THIS_THREAD{$ctx} ) {
	    # remove any verify callback for this context
	    if ( $self->{has_verifycb}) {
		$DEBUG>=3 && DEBUG("free ctx $ctx callback" );
		Net::SSLeay::CTX_set_verify($ctx, 0,undef);
	    }
	    $DEBUG>=3 && DEBUG("OK free ctx $ctx" );
	    Net::SSLeay::CTX_free($ctx);
	}
    }
    delete(@{$self}{'context','session_cache'});
}

package IO::Socket::SSL::Session_Cache;
use strict;

sub new {
    my ($class, $size) = @_;
    $size>0 or return;
    return bless { _maxsize => $size }, $class;
}


sub get_session {
    my ($self, $key) = @_;
    my $session = $self->{$key} || return;
    return $session->{session} if ($self->{'_head'} eq $session);
    $session->{prev}->{next} = $session->{next};
    $session->{next}->{prev} = $session->{prev};
    $session->{next} = $self->{'_head'};
    $session->{prev} = $self->{'_head'}->{prev};
    $self->{'_head'}->{prev} = $self->{'_head'}->{prev}->{next} = $session;
    $self->{'_head'} = $session;
    return $session->{session};
}

sub add_session {
    my ($self, $key, $val) = @_;
    return if ($key eq '_maxsize' or $key eq '_head');

    if ((keys %$self) > $self->{'_maxsize'} + 1) {
	my $last = $self->{'_head'}->{prev};
	Net::SSLeay::SESSION_free($last->{session});
	delete($self->{$last->{key}});
	$self->{'_head'}->{prev} = $self->{'_head'}->{prev}->{prev};
	delete($self->{'_head'}) if ($self->{'_maxsize'} == 1);
    }

    my $session = $self->{$key} = { session => $val, key => $key };

    if ($self->{'_head'}) {
	$session->{next} = $self->{'_head'};
	$session->{prev} = $self->{'_head'}->{prev};
	$self->{'_head'}->{prev}->{next} = $session;
	$self->{'_head'}->{prev} = $session;
    } else {
	$session->{next} = $session->{prev} = $session;
    }
    $self->{'_head'} = $session;
    return $session;
}

sub DESTROY {
    my $self = shift;
    delete(@{$self}{'_head','_maxsize'});
    foreach my $key (keys %$self) {
	Net::SSLeay::SESSION_free($self->{$key}->{session});
    }
}


1;

__END__

=head1 NAME

IO::Socket::SSL -- SSL sockets with IO::Socket interface

=head1 SYNOPSIS

    use strict;
    use IO::Socket::SSL;

    # simple HTTP client -----------------------------------------------
    my $sock = IO::Socket::SSL->new(
	# where to connect
	PeerHost => "www.example.com",
	PeerPort => "https",

	# certificate verification
	SSL_verify_mode => SSL_VERIFY_PEER,

	# location of CA store
	# need only be given if default store should not be used
	SSL_ca_path => '/etc/ssl/certs', # typical CA path on Linux
	SSL_ca_file => '/etc/ssl/cert.pem', # typical CA file on BSD

	# easy hostname verification 
	SSL_verifycn_name => 'foo.bar', # defaults to PeerHost
	SSL_verifycn_schema => 'http',

	# SNI support
	SSL_hostname => 'foo.bar', # defaults to PeerHost

    ) or die "failed connect or ssl handshake: $!,$SSL_ERROR";

    # send and receive over SSL connection
    print $client "GET / HTTP/1.0\r\n\r\n";
    print <$client>;

    # simple server ----------------------------------------------------
    my $server = IO::Socket::SSL->new(
	# where to listen
	LocalAddr => '127.0.0.1',
	LocalPort => 8080,
	Listen => 10,

	# which certificate to offer
	# with SNI support there can be different certificates per hostname
	SSL_cert_file => 'cert.pem',
	SSL_key_file => 'key.pem',
    ) or die "failed to listen: $!";

    # accept client
    my $client = $server->accept or die 
	"failed to accept or ssl handshake: $!,$SSL_ERROR";

    # Upgrade existing socket to SSL ---------------------------------
    my $sock = IO::Socket::INET->new('imap.example.com:imap');
    # ... receive greeting, send STARTTLS, receive ok ...
    IO::Socket::SSL->start_SSL($sock,
	SSL_verify_mode => SSL_VERIFY_PEER,
	SSL_ca_path => '/etc/ssl/certs',
	...
    ) or die "failed to upgrade to SSL: $SSL_ERROR";

    # manual name verification, could also be done in start_SSL with
    # SSL_verifycn_name etc
    $client->verify_hostname( 'imap.example.com','imap' )
	or die "hostname verification failed";

    # all data are now SSL encrypted
    print $sock .... 


=head1 DESCRIPTION

This module provides an interface to SSL sockets, similar to other IO::Socket
modules. Because of that, it can be used to make existing programs using
IO::Socket::INET or similar modules to provide SSL encryption without much
effort.
IO::Socket::SSL supports all the extra features that one needs to write a
full-featured SSL client or server application: multiple SSL contexts, cipher
selection, certificate verification, Server Name Indication (SNI), Next
Protocol Negotiation (NPN), SSL version selection and more.

If you have never used SSL before, you should read the appendix labelled 'Using SSL'
before attempting to use this module.

If you are trying to use it with threads see the BUGS section.

=head1 METHODS

IO::Socket::SSL inherits from another IO::Socket module.
The choice of the super class depends on the installed modules:

=over 4

=item *

If IO::Socket::IP with at least version 0.20 is installed it will use this
module as super class, transparently providing IPv6 and IPv4 support.

=item *

If IO::Socket::INET6 is installed it will use this module as super class,
transparently providing IPv6 and IPv4 support.

=item *

Otherwise it will fall back to IO::Socket::INET, which is a perl core module.
With IO::Socket::INET you only get IPv4 support.

=back

Please be aware, that with the IPv6 capable super classes, it will lookup first
for the IPv6 address of a given hostname. If the resolver provides an IPv6
address, but the host cannot be reached by IPv6, there will be no automatic 
fallback to IPv4.
To avoid these problems you can either force IPv4 by specifying and AF_INET
as C<Domain> of the socket or globally enforce IPv4 by loading IO::Socket::SSL
with the option 'inet4'.

IO::Socket::SSL will provide all of the methods of its super class, but
sometimes it will override them to match the behavior expected from SSL or to
provide additional arguments.

The new or changed methods are described below, but please read also the
section about SSL specific error handling.

=over 4

=item B<new(...)>

Creates a new IO::Socket::SSL object.  You may use all the friendly options
that came bundled with IO::Socket::INET, plus (optionally) the ones that follow:

=over 2

=item SSL_hostname

This can be given to specify the hostname used for SNI, which is needed if you
have multiple SSL hostnames on the same IP address. If not given it will try to
determine hostname from PeerAddr, which will fail if only IP was given or if
this argument is used within start_SSL.

If you want to disable SNI set this argument to ''.

Currently only supported for the client side and will be ignored for the server
side.

See section "SNI Support" for details of SNI the support.

=item SSL_version

Sets the version of the SSL protocol used to transmit data. 
'SSLv23' auto-negotiates between SSLv2 and SSLv3, while 'SSLv2', 'SSLv3',
'TLSv1', 'TLSv1_1' or 'TLSv1_2' restrict the protocol to the specified version.
All values are case-insensitive.  Instead of 'TLSv1_1' and 'TLSv1_2' one can
also use 'TLSv11' and 'TLSv12'.  Support for 'TLSv1_1' and 'TLSv1_2' requires
recent versions of Net::SSLeay and openssl.

You can limit to set of supported protocols by adding !version separated by ':'.

The default SSL_version is defined by underlying cryptographic library.
E.g. 'SSLv23:!SSLv2' means, that SSLv2, SSLv3 and
TLSv1 are supported for initial protocol handshakes, but SSLv2 will not be
accepted, leaving only SSLv3 and TLSv1. You can also use !TLSv1_1 and !TLSv1_2
to disable TLS versions 1.1 and 1.2 while allowing TLS version 1.0.

Setting the version instead to 'TLSv1' will probably break interaction with
lots of clients which start with SSLv2 and then upgrade to TLSv1. On the other
side some clients just close the connection when they receive a TLS version 1.1
request. In this case setting the version to 'SSLv23:!SSLv2:!TLSv1_1:!TLSv1_2'
might help.

=item SSL_cipher_list

If this option is set the cipher list for the connection will be set to the
given value, e.g. something like 'ALL:!LOW:!EXP:!ADH'. Look into the OpenSSL
documentation (L<http://www.openssl.org/docs/apps/ciphers.html#CIPHER_STRINGS>)
for more details.

If this option is not set or is set to '', OpenSSL builtin default (whatever
this is) will be used.

=item SSL_honor_cipher_order

If this option is true the cipher order the server specified is used instead
of the order proposed by the client. To mitigate BEAST attack you might use
something like

  SSL_honor_cipher_order => 1,
  SSL_cipher_list => 'RC4-SHA:ALL:!ADH:!LOW',

=item SSL_use_cert

If this is true, it forces IO::Socket::SSL to use a certificate and key, even if
you are setting up an SSL client.  If this is set to 0 (the default), then you will
only need a certificate and key if you are setting up a server.

SSL_use_cert will implicitly be set if SSL_server is set.
For convenience it is also set if it was not given but a cert was given for use
(SSL_cert_file or similar).

=item SSL_server

Set this option to a true value, if the socket should be used as a server.
If this is not explicitly set it is assumed, if the Listen parameter is given
when creating the socket.

=item SSL_cert_file

If your SSL certificate is not in the default place (F<certs/server-cert.pem> for servers,
F<certs/client-cert.pem> for clients), then you should use this option to specify the
location of your certificate.  
A certificate is usually needed for an SSL server, but might also be needed, if
the client should authorize itself with a certificate.

If your SSL server should be able to use different certificates on the same IP
address, depending on the name given by SNI, you can use a hash reference
instead of a file with C<<hostname => cert_file>>.

Examples:

 SSL_cert_file => 'mycert.pem'

 SSL_cert_file => {
    "foo.example.org" => 'foo.pem',
    "bar.example.org" => 'bar.pem',
    # used when nothing matches or client does not support SNI
    '' => 'default.pem', 
 }

=item SSL_cert

This option can be used instead of C<SSL_cert_file> to specify the certificate.

Instead with a file the certificate is given as an X509* object or array of
X509* objects, where the first X509* is the internal representation of the
certificate while the following ones are extra certificates.
The option is useful if you create your certificate dynamically (like in a SSL
intercepting proxy) or get it from a string (see openssl PEM_read_bio_X509 etc
for getting a X509* from a string).

For SNI support a hash reference can be given, similar to the
C<SSL_cert_file> option.

=item SSL_key_file

If your RSA private key is not in default place (F<certs/server-key.pem> for servers,
F<certs/client-key.pem> for clients), then this is the option that you would use to
specify a different location.  Keys should be PEM formatted, and if they are
encrypted, you will be prompted to enter a password before the socket is formed
(unless you specified the SSL_passwd_cb option).

For SNI support a hash reference can be given, similar to the
C<SSL_cert_file> option.

=item SSL_key

This option can be used instead of C<SSL_key> to specify the certificate.
Instead of a file an EVP_PKEY* should be given.
This option is useful if you don't have your key in a file but create it
dynamically or get it from a string (see openssl PEM_read_bio_PrivateKey etc
for getting a EVP_PKEY* from a string).

For SNI support a hash reference can be given, similar to the
C<SSL_key> option.

=item SSL_dh_file

If you want Diffie-Hellman key exchange you need to supply a suitable file here
or use the SSL_dh parameter. See dhparam command in openssl for more information.
To create a server which provides perfect forward secrecy you need to either
give the DH parameters or (better, because faster) the ECDH curve.

=item SSL_dh

Like SSL_dh_file, but instead of giving a file you use a preloaded or generated DH*.

=item SSL_ecdh_curve

If you want Elliptic Curve Diffie-Hellmann key exchange you need to supply the
OID or NID of a suitable curve (like 'prime256v1') here.
To create a server which provides perfect forward secrecy you need to either
give the DH parameters or (better, because faster) the ECDH curve.

=item SSL_passwd_cb

If your private key is encrypted, you might not want the default password prompt from
Net::SSLeay.  This option takes a reference to a subroutine that should return the
password required to decrypt your private key.

=item SSL_ca_file

If you want to verify that the peer certificate has been signed by a reputable
certificate authority, then you can use this option to locate the file
containing the certificateZ<>(s) of the reputable certificate authorities if it is
not already in the file F<certs/my-ca.pem> or in a system-wide certificate authority certificates store.
If you definitely want no SSL_ca_file used you should set it to undef.

=item SSL_ca_path

If you are unusually friendly with the OpenSSL documentation, you might have set
yourself up a directory containing several trusted certificates as separate files
as well as an index of the certificates.  If you want to use that directory for
validation purposes, and that directory is not F<ca/>, then use this option to
point IO::Socket::SSL to the right place to look.
If you definitely want no SSL_ca_path used you should set it to undef.

=item SSL_verify_mode

This option sets the verification mode for the peer certificate.  
You may combine SSL_VERIFY_PEER (verify_peer), SSL_VERIFY_FAIL_IF_NO_PEER_CERT
(fail verification if no peer certificate exists; ignored for clients),
SSL_VERIFY_CLIENT_ONCE (verify client once; ignored for clients).
See OpenSSL man page for SSL_CTX_set_verify for more information.

The default is SSL_VERIFY_NONE for server  (e.g. no check for client
certificate).
For historical reasons the default for client is currently also SSL_VERIFY_NONE,
but this will change to SSL_VERIFY_PEER in the near future. To aid transition a
warning is issued if the client is used with the default SSL_VERIFY_NONE, unless
SSL_verify_mode was explicitly set by the application.

=item SSL_verify_callback

If you want to verify certificates yourself, you can pass a sub reference along
with this parameter to do so.  When the callback is called, it will be passed:

=over 4

=item 1.
a true/false value that indicates what OpenSSL thinks of the certificate,

=item 2.
a C-style memory address of the certificate store,

=item 3.
a string containing the certificate's issuer attributes and owner attributes, and

=item 4.
a string containing any errors encountered (0 if no errors).

=item 5.
a C-style memory address of the peer's own certificate (convertible to
PEM form with Net::SSLeay::PEM_get_string_X509()).

=back

The function should return 1 or 0, depending on whether it thinks the certificate
is valid or invalid.  The default is to let OpenSSL do all of the busy work.

The callback will be called for each element in the certificate chain.

See the OpenSSL documentation for SSL_CTX_set_verify for more information.

=item SSL_verifycn_scheme

Set the scheme used to automatically verify the hostname of the peer.
See the information about the verification schemes in B<verify_hostname>.

The default is undef, e.g. to not automatically verify the hostname.
If no verification is done the other B<SSL_verifycn_*> options have
no effect, but you might still do manual verification by calling
B<verify_hostname>.

=item SSL_verifycn_name

Set the name which is used in verification of hostname. If SSL_verifycn_scheme
is set and no SSL_verifycn_name is given it will try to use the PeerHost and
PeerAddr settings and fail if no name can be determined.

Using PeerHost or PeerAddr works only if you create the connection directly
with C<< IO::Socket::SSL->new >>, if an IO::Socket::INET object is upgraded
with B<start_SSL> the name has to be given in B<SSL_verifycn_name>.

=item SSL_check_crl

If you want to verify that the peer certificate has not been revoked
by the signing authority, set this value to true. OpenSSL will search
for the CRL in your SSL_ca_path, or use the file specified by
SSL_crl_file.  See the Net::SSLeay documentation for more details.
Note that this functionality appears to be broken with OpenSSL <
v0.9.7b, so its use with lower versions will result in an error.

=item SSL_crl_file

If you want to specify the CRL file to be used, set this value to the
pathname to be used.  This must be used in addition to setting
SSL_check_crl.

=item SSL_reuse_ctx

If you have already set the above options (SSL_version through SSL_check_crl;
this does not include SSL_cipher_list yet) for a previous instance of
IO::Socket::SSL, then you can reuse the SSL context of that instance by passing
it as the value for the SSL_reuse_ctx parameter.  You may also create a
new instance of the IO::Socket::SSL::SSL_Context class, using any context options
that you desire without specifying connection options, and pass that here instead.

If you use this option, all other context-related options that you pass
in the same call to new() will be ignored unless the context supplied was invalid.
Note that, contrary to versions of IO::Socket::SSL below v0.90, a global SSL context
will not be implicitly used unless you use the set_default_context() function.

=item SSL_create_ctx_callback

With this callback you can make individual settings to the context after it
got created and the default setup was done.
The callback will be called with the CTX object from Net::SSLeay as the single
argument.

Example for limiting the server session cache size:

  SSL_create_ctx_callback => sub { 
      my $ctx = shift;
	  Net::SSLeay::CTX_sess_set_cache_size($ctx,128);
  }

=item SSL_session_cache_size

If you make repeated connections to the same host/port and the SSL renegotiation time
is an issue, you can turn on client-side session caching with this option by specifying a
positive cache size.  For successive connections, pass the SSL_reuse_ctx option to
the new() calls (or use set_default_context()) to make use of the cached sessions.
The session cache size refers to the number of unique host/port pairs that can be
stored at one time; the oldest sessions in the cache will be removed if new ones are
added.

This option does not effect the session cache a server has for it's clients, e.g. it
does not affect SSL objects with SSL_server set.

=item SSL_session_cache

Specifies session cache object which should be used instead of creating a new.
Overrules SSL_session_cache_size.
This option is useful if you want to reuse the cache, but not the rest of
the context.

A session cache object can be created using
C<< IO::Socket::SSL::Session_Cache->new( cachesize ) >>.

Use set_default_session_cache() to set a global cache object.

=item SSL_session_id_context

This gives an id for the servers session cache. It's necessary if you want
clients to connect with a client certificate. If not given but SSL_verify_mode
specifies the need for client certificate a context unique id will be picked.

=item SSL_error_trap

When using the accept() or connect() methods, it may be the case that the
actual socket connection works but the SSL negotiation fails, as in the case of
an HTTP client connecting to an HTTPS server.  Passing a subroutine ref attached
to this parameter allows you to gain control of the orphaned socket instead of having it
be closed forcibly.	 The subroutine, if called, will be passed two parameters:
a reference to the socket on which the SSL negotiation failed and the full
text of the error message.

=item SSL_npn_protocols

If used on the server side it specifies list of protocols advertised by SSL
server as an array ref, e.g. ['spdy/2','http1.1']. 
On the client side it specifies the protocols offered by the client for NPN
as an array ref.
See also method L<next_proto_negotiated>.

Next Protocol Negotioation (NPN) is available with Net::SSLeay 1.46+ and openssl-1.0.1+.
To check support you might call C<IO::Socket::SSL->can_npn()>.
If you use this option with an unsupported Net::SSLeay/OpenSSL it will 
throw an error.

=back

=item B<close(...)>

There are a number of nasty traps that lie in wait if you are not careful about using
close().  The first of these will bite you if you have been using shutdown() on your
sockets.  Since the SSL protocol mandates that a SSL "close notify" message be
sent before the socket is closed, a shutdown() that closes the socket's write channel
will cause the close() call to hang.  For a similar reason, if you try to close a
copy of a socket (as in a forking server) you will affect the original socket as well.
To get around these problems, call close with an object-oriented syntax
(e.g. $socket->close(SSL_no_shutdown => 1))
and one or more of the following parameters:

=over 2

=item SSL_no_shutdown

If set to a true value, this option will make close() not use the SSL_shutdown() call
on the socket in question so that the close operation can complete without problems
if you have used shutdown() or are working on a copy of a socket.

=item SSL_fast_shutdown

If set to true only a unidirectional shutdown will be done, e.g. only the
close_notify (see SSL_shutdown(3)) will be called. Otherwise a bidirectional
shutdown will be done. If used within close() it defaults to true, if used
within stop_SSL() it defaults to false.

=item SSL_ctx_free

If you want to make sure that the SSL context of the socket is destroyed when
you close it, set this option to a true value.

=back

=item B<peek(...)>

This function has exactly the same syntax as sysread(), and performs nearly the same
task (reading data from the socket) but will not advance the read position so
that successive calls to peek() with the same arguments will return the same results.
This function requires OpenSSL 0.9.6a or later to work.


=item B<pending()>

This function will let you know how many bytes of data are immediately ready for reading
from the socket.  This is especially handy if you are doing reads on a blocking socket
or just want to know if new data has been sent over the socket.


=item B<get_cipher()>

Returns the string form of the cipher that the IO::Socket::SSL object is using.

=item B<dump_peer_certificate()>

Returns a parsable string with select fields from the peer SSL certificate.	 This
method directly returns the result of the dump_peer_certificate() method of Net::SSLeay.

=item B<peer_certificate($field)>

If a peer certificate exists, this function can retrieve values from it.
If no field is given the internal representation of certificate from Net::SSLeay is
returned.
The following fields can be queried:

=over 8

=item authority (alias issuer)

The certificate authority which signed the certificate.

=item owner (alias subject)

The owner of the certificate.

=item commonName (alias cn) - only for Net::SSLeay version >=1.30

The common name, usually the server name for SSL certificates.

=item subjectAltNames - only for Net::SSLeay version >=1.33

Alternative names for the subject, usually different names for the same
server, like example.org, example.com, *.example.com.

It returns a list of (typ,value) with typ GEN_DNS, GEN_IPADD etc (these
constants are exported from IO::Socket::SSL).
See Net::SSLeay::X509_get_subjectAltNames.

=back

=item B<get_servername>

This gives the name requested by the client if Server Name Indication
(SNI) was used.

=item B<verify_hostname($hostname,$scheme)>

This verifies the given hostname against the peer certificate using the
given scheme. Hostname is usually what you specify within the PeerAddr.

Verification of hostname against a certificate is different between various
applications and RFCs. Some scheme allow wildcards for hostnames, some only
in subjectAltNames, and even their different wildcard schemes are possible.

To ease the verification the following schemes are predefined:

=over 8

=item ldap (rfc4513), pop3,imap,acap (rfc2995), nntp (rfc4642)

Simple wildcards in subjectAltNames are possible, e.g. *.example.org matches
www.example.org but not lala.www.example.org. If nothing from subjectAltNames
match it checks against the common name, but there are no wildcards allowed.

=item http (rfc2818), alias is www

Extended wildcards in subjectAltNames and common name are possible, e.g. 
*.example.org or even www*.example.org. The common
name will be only checked if no names are given in subjectAltNames.

=item smtp (rfc3207)

This RFC doesn't say much useful about the verification so it just assumes
that subjectAltNames are possible, but no wildcards are possible anywhere.

=item none

No verification will be done.
Actually is does not make any sense to call verify_hostname in this case.

=back

The scheme can be given either by specifying the name for one of the above predefined
schemes, or by using a hash which can have the following keys and values:

=over 8

=item check_cn:  0|'always'|'when_only'

Determines if the common name gets checked. If 'always' it will always be checked
(like in ldap), if 'when_only' it will only be checked if no names are given in
subjectAltNames (like in http), for any other values the common name will not be checked.

=item wildcards_in_alt: 0|'leftmost'|'anywhere'

Determines if and where wildcards in subjectAltNames are possible. If 'leftmost'
only cases like *.example.org will be possible (like in ldap), for 'anywhere'
www*.example.org is possible too (like http), dangerous things like but www.*.org
or even '*' will not be allowed.

=item wildcards_in_cn: 0|'leftmost'|'anywhere'

Similar to wildcards_in_alt, but checks the common name. There is no predefined
scheme which allows wildcards in common names.

=item callback: \&coderef

If you give a subroutine for verification it will be called with the arguments
($hostname,$commonName,@subjectAltNames), where hostname is the name given for
verification, commonName is the result from peer_certificate('cn') and
subjectAltNames is the result from peer_certificate('subjectAltNames').

All other arguments for the verification scheme will be ignored in this case.

=back

=item B<next_proto_negotiated()>

This method returns the name of negotiated protocol - e.g. 'http/1.1'. It works
for both client and server side of SSL connection.

NPN support is available with Net::SSLeay 1.46+ and openssl-1.0.1+.
To check support you might call C<IO::Socket::SSL->can_npn()>.

=item B<errstr()>

Returns the last error (in string form) that occurred.	If you do not have a real
object to perform this method on, call IO::Socket::SSL::errstr() instead.

For read and write errors on non-blocking sockets, this method may include the string
C<SSL wants a read first!> or C<SSL wants a write first!> meaning that the other side
is expecting to read from or write to the socket and wants to be satisfied before you
get to do anything. But with version 0.98 you are better comparing the global exported
variable $SSL_ERROR against the exported symbols SSL_WANT_READ and SSL_WANT_WRITE.

=item B<opened()>

This returns false if the socket could not be opened, 1 if the socket could be opened
and the SSL handshake was successful done and -1 if the underlying IO::Handle is open,
but the SSL handshake failed.

=item B<< IO::Socket::SSL->start_SSL($socket, ... ) >>

This will convert a glob reference or a socket that you provide to an IO::Socket::SSL
object.	 You may also pass parameters to specify context or connection options as with
a call to new().  If you are using this function on an accept()ed socket, you must
set the parameter "SSL_server" to 1, i.e. IO::Socket::SSL->start_SSL($socket, SSL_server => 1).
If you have a class that inherits from IO::Socket::SSL and you want the $socket to be blessed
into your own class instead, use MyClass->start_SSL($socket) to achieve the desired effect.

Note that if start_SSL() fails in SSL negotiation, $socket will remain blessed in its
original class.	 For non-blocking sockets you better just upgrade the socket to
IO::Socket::SSL and call accept_SSL or connect_SSL and the upgraded object. To
just upgrade the socket set B<SSL_startHandshake> explicitly to 0. If you call start_SSL
w/o this parameter it will revert to blocking behavior for accept_SSL and connect_SSL.

If given the parameter "Timeout" it will stop if after the timeout no SSL connection
was established. This parameter is only used for blocking sockets, if it is not given the
default Timeout from the underlying IO::Socket will be used.

=item B<stop_SSL(...)>

This is the opposite of start_SSL(), e.g. it will shutdown the SSL connection
and return to the class before start_SSL(). It gets the same arguments as close(),
in fact close() calls stop_SSL() (but without downgrading the class).

Will return true if it succeeded and undef if failed. This might be the case for
non-blocking sockets. In this case $! is set to EAGAIN and the ssl error to
SSL_WANT_READ or SSL_WANT_WRITE. In this case the call should be retried again with
the same arguments once the socket is ready is until it succeeds.

=item B<< IO::Socket::SSL->new_from_fd($fd, ...) >>

This will convert a socket identified via a file descriptor into an SSL socket.
Note that the argument list does not include a "MODE" argument; if you supply one,
it will be thoughtfully ignored (for compatibility with IO::Socket::INET).	Instead,
a mode of '+<' is assumed, and the file descriptor passed must be able to handle such
I/O because the initial SSL handshake requires bidirectional communication.

=item B<IO::Socket::SSL::set_default_context(...)>

You may use this to make IO::Socket::SSL automatically re-use a given context (unless
specifically overridden in a call to new()).  It accepts one argument, which should
be either an IO::Socket::SSL object or an IO::Socket::SSL::SSL_Context object.	See
the SSL_reuse_ctx option of new() for more details.	 Note that this sets the default
context globally, so use with caution (esp. in mod_perl scripts).

=item B<IO::Socket::SSL::set_default_session_cache(...)>

You may use this to make IO::Socket::SSL automatically re-use a given session cache
(unless specifically overridden in a call to new()).  It accepts one argument, which should
be an IO::Socket::SSL::Session_Cache object or similar (e.g something which implements
get_session and add_session like IO::Socket::SSL::Session_Cache does).
See the SSL_session_cache option of new() for more details.	 Note that this sets the default
cache globally, so use with caution.

=item B<IO::Socket::SSL::set_defaults(%args)>

With this function one can set defaults for all SSL_* parameter used for creation of
the context, like the SSL_verify* parameter.

=over 8

=item mode - set default SSL_verify_mode

=item callback - set default SSL_verify_callback

=item scheme - set default SSL_verifycn_scheme

=item name - set default SSL_verifycn_name

If not given and scheme is hash reference with key callback it will be set to 'unknown'

=back

=back

The following methods are unsupported (not to mention futile!) and IO::Socket::SSL
will emit a large CROAK() if you are silly enough to use them:

=over 4

=item truncate

=item stat

=item ungetc

=item setbuf

=item setvbuf

=item fdopen

=item send/recv

Note that send() and recv() cannot be reliably trapped by a tied filehandle (such as
that used by IO::Socket::SSL) and so may send unencrypted data over the socket.	 Object-oriented
calls to these functions will fail, telling you to use the print/printf/syswrite
and read/sysread families instead.

=back

=head1 ERROR HANDLING

If an SSL specific error occurs the global variable C<$SSL_ERROR> will be set.
If the error occurred on an existing SSL socket the method C<errstr> will
give access to the latest socket specific error.
Both C<$SSL_ERROR> and C<errstr> method give a dualvar similar to C<$!>, e.g.
providing an error number in numeric context or an error description in string
context.

=head1 NON-BLOCKING I/O

If you have a non-blocking socket, the expected behavior on read, write, accept
or connect is to set C<$!> to EAGAIN if the operation can not be completed
immediately.

With SSL there are cases, like with SSL handshakes, where the write operation
can not be completed until it can read from the socket or vice versa. 
In these cases C<$!> is set to EGAIN like expected, and additionally
C<$SSL_ERROR> is set to either SSL_WANT_READ or SSL_WANT_WRITE.
Thus if you get EAGAIN on a SSL socket you must check C<$SSL_ERROR> for
SSL_WANT_* and adapt your event mask accordingly.

Using readline on non-blocking sockets does not make much sense and I would
advise against using it.
And, while the behavior is not documented for other L<IO::Socket> classes, it
will try to emulate the behavior seen there, e.g. to return the received data
instead of blocking, even if the line is not complete. If an unrecoverable error
occurs it will return nothing, even if it already received some data.

=head1 SNI Support

Newer extensions to SSL can distinguish between multiple hostnames on the same
IP address using Server Name Indication (SNI). 

Support for SNI on the client side was added somewhere in the OpenSSL 0.9.8
series, but only with 1.0 a bug was fixed when the server could not decide about
its hostname. Therefore client side SNI is only supported with OpenSSL 1.0 or
higher in L<IO::Socket::SSL>.
With a supported version, SNI is used automatically on the client side, if it can
determine the hostname from C<PeerAddr> or C<PeerHost>. On unsupported OpenSSL
versions it will silently not use SNI.
The hostname can also be given explicitly given with C<SSL_hostname>, but in
this case it will throw in error, if SNI is not supported.
To check for support you might call C<IO::Socket::SSL->can_client_sni()>.

On the server side earlier versions of OpenSSL are supported, but only together
with L<Net::SSLeay> version >= 1.50.
To check for support you might call C<IO::Socket::SSL->can_server_sni()>.
If server side SNI is supported, you might specify different certificates per
host with C<SSL_cert*> and C<SSL_key*>, and check the requested name using
C<get_servername>.

=head1 RETURN VALUES

A few changes have gone into IO::Socket::SSL v0.93 and later with respect to
return values.	The behavior on success remains unchanged, but for I<all> functions,
the return value on error is now an empty list.	 Therefore, the return value will be
false in all contexts, but those who have been using the return values as arguments
to subroutines (like C<mysub(IO::Socket::SSL(...)->new, ...)>) may run into problems.
The moral of the story: I<always> check the return values of these functions before
using them in any way that you consider meaningful.


=head1 DEBUGGING

If you are having problems using IO::Socket::SSL despite the fact that can recite backwards
the section of this documentation labelled 'Using SSL', you should try enabling debugging.	To
specify the debug level, pass 'debug#' (where # is a number from 0 to 3) to IO::Socket::SSL
when calling it.
The debug level will also be propagated to Net::SSLeay::trace, see also L<Net::SSLeay>:

=over 4

=item use IO::Socket::SSL qw(debug0);

No debugging (default).

=item use IO::Socket::SSL qw(debug1);

Print out errors from IO::Socket::SSL and ciphers from Net::SSLeay.

=item use IO::Socket::SSL qw(debug2);

Print also information about call flow from IO::Socket::SSL and progress
information from Net::SSLeay.

=item use IO::Socket::SSL qw(debug3);

Print also some data dumps from IO::Socket::SSL and from Net::SSLeay.

=back

=head1 EXAMPLES

See the 'example' directory.

=head1 BUGS

IO::Socket::SSL depends on Net::SSLeay.  Up to version 1.43 of Net::SSLeay
it was not thread safe, although it did probably work if you did not use 
SSL_verify_callback and SSL_password_cb.

If you use IO::Socket::SSL together with threads you should load it (e.g. use or
require) inside the main thread before creating any other threads which use it.
This way it is much faster because it will be initialized only once. Also there
are reports that it might crash the other way.

Creating an IO::Socket::SSL object in one thread and closing it in another
thread will not work.

IO::Socket::SSL does not work together with Storable::fd_retrieve/fd_store.
See BUGS file for more information and how to work around the problem.

Non-blocking and timeouts (which are based on non-blocking) are not
supported on Win32, because the underlying IO::Socket::INET does not support
non-blocking on this platform.

If you have a server and it looks like you have a memory leak you might 
check the size of your session cache. Default for Net::SSLeay seems to be 
20480, see the example for SSL_create_ctx_callback for how to limit it.

The default for SSL_verify_mode on the client is currently SSL_VERIFY_NONE,
which is a very bad idea, thus the default will change in the near future.
See documentation for SSL_verify_mode for more information.

=head1 LIMITATIONS

IO::Socket::SSL uses Net::SSLeay as the shiny interface to OpenSSL, which is
the shiny interface to the ugliness of SSL.	 As a result, you will need both Net::SSLeay
and OpenSSL on your computer before using this module.

If you have Scalar::Util (standard with Perl 5.8.0 and above) or WeakRef, IO::Socket::SSL
sockets will auto-close when they go out of scope, just like IO::Socket::INET sockets.	If
you do not have one of these modules, then IO::Socket::SSL sockets will stay open until the
program ends or you explicitly close them.	This is due to the fact that a circular reference
is required to make IO::Socket::SSL sockets act simultaneously like objects and glob references.

=head1 DEPRECATIONS

The following functions are deprecated and are only retained for compatibility:

=over 2

=item context_init()

use the SSL_reuse_ctx option if you want to re-use a context


=item socketToSSL() and socket_to_SSL()

use IO::Socket::SSL->start_SSL() instead

=item kill_socket()

use close() instead

=item get_peer_certificate()

use the peer_certificate() function instead.
Used to return X509_Certificate with methods subject_name and issuer_name.
Now simply returns $self which has these methods (although deprecated).

=item issuer_name()

use peer_certificate( 'issuer' ) instead

=item subject_name()

use peer_certificate( 'subject' ) instead

=back

=head1 SEE ALSO

IO::Socket::INET, IO::Socket::INET6, IO::Socket::IP, Net::SSLeay.

=head1 AUTHORS

Steffen Ullrich, <steffen at genua.de> is the current maintainer.

Peter Behroozi, <behrooz at fas.harvard.edu> (Note the lack of an "i" at the end of "behrooz")

Marko Asplund, <marko.asplund at kronodoc.fi>, was the original author of IO::Socket::SSL.

Patches incorporated from various people, see file Changes.

=head1 COPYRIGHT

The original versions of this module are Copyright (C) 1999-2002 Marko Asplund.

The rewrite of this module is Copyright (C) 2002-2005 Peter Behroozi.

Versions 0.98 and newer are Copyright (C) 2006-2013 Steffen Ullrich.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.


=head1 Appendix: Using SSL

If you are unfamiliar with the way OpenSSL works, good references may be found in
both the book "Network Security with OpenSSL" (Oreilly & Assoc.) and the web site
L<http://www.tldp.org/HOWTO/SSL-Certificates-HOWTO/>.  Read on for a quick overview.

=head2 The Long of It (Detail)

The usual reason for using SSL is to keep your data safe.  This means that not only
do you have to encrypt the data while it is being transported over a network, but
you also have to make sure that the right person gets the data.	 To accomplish this
with SSL, you have to use certificates.	 A certificate closely resembles a
Government-issued ID (at least in places where you can trust them).	 The ID contains some sort of
identifying information such as a name and address, and is usually stamped with a seal
of Government Approval.	 Theoretically, this means that you may trust the information on
the card and do business with the owner of the card.  The same ideas apply to SSL certificates,
which have some identifying information and are "stamped" [most people refer to this as
I<signing> instead] by someone (a Certificate Authority) who you trust will adequately
verify the identifying information.	 In this case, because of some clever number theory,
it is extremely difficult to falsify the stamping process.	Another useful consequence
of number theory is that the certificate is linked to the encryption process, so you may
encrypt data (using information on the certificate) that only the certificate owner can
decrypt.

What does this mean for you?  It means that at least one person in the party has to
have an ID to get drinks :-).  Seriously, it means that one of the people communicating
has to have a certificate to ensure that your data is safe.	 For client/server
interactions, the server must B<always> have a certificate.	 If the server wants to
verify that the client is safe, then the client must also have a personal certificate.
To verify that a certificate is safe, one compares the stamped "seal" [commonly called
an I<encrypted digest/hash/signature>] on the certificate with the official "seal" of
the Certificate Authority to make sure that they are the same.	To do this, you will
need the [unfortunately named] certificate of the Certificate Authority.  With all these
in hand, you can set up a SSL connection and be reasonably confident that no-one is
reading your data.

=head2 The Short of It (Summary)

For servers, you will need to generate a cryptographic private key and a certificate
request.  You will need to send the certificate request to a Certificate Authority to
get a real certificate back, after which you can start serving people.	For clients,
you will not need anything unless the server wants validation, in which case you will
also need a private key and a real certificate.	 For more information about how to
get these, see L<http://www.modssl.org/docs/2.8/ssl_faq.html#ToC24>.

=cut
