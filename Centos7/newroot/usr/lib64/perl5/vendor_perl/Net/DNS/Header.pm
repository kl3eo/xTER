package Net::DNS::Header;

#
# $Id: Header.pm 1086 2012-12-18 15:13:35Z willem $
#
use vars qw($VERSION);
$VERSION = (qw$LastChangedRevision: 1086 $)[1];


=head1 NAME

Net::DNS::Header - DNS packet header

=head1 SYNOPSIS

    use Net::DNS;

    $packet = new Net::DNS::Packet;
    $header = $packet->header;


=head1 DESCRIPTION

C<Net::DNS::Header> represents the header portion of a DNS packet.

=cut


use strict;
use integer;
use Carp;

use Net::DNS::Parameters;
require Net::DNS::RR;


=head1 METHODS

=head2 new

    $header = new Net::DNS::Header($packet);

Constructor method which returns a C<Net::DNS::Header> object
representing the header section of the specified packet.

=cut

sub new {
	my $class  = shift;
	my $packet = shift;

	croak 'object model violation' unless $packet->isa(qw(Net::DNS::Packet));

	bless { xbody => $packet }, $class;
}


=head2 string

    print $packet->header->string;

Returns a string representation of the packet header.

=cut

sub string {
	my $self = shift;

	my $id	   = $self->id;
	my $qr	   = $self->qr;
	my $opcode = $self->opcode;
	my $rcode  = $self->rcode;
	my $qd	   = $self->qdcount;
	my $an	   = $self->ancount;
	my $ns	   = $self->nscount;
	my $ar	   = $self->arcount;

	my $opt = $self->edns;
	my $edns = ( $opt->isa(qw(Net::DNS::RR::OPT)) && not $opt->default ) ? $opt->string : '';

	my $retval;
	return $retval = <<EOF if $opcode eq 'UPDATE';
;;	id = $id
;;	qr = $qr		opcode = $opcode	rcode = $rcode
;;	zocount = $qd	prcount = $an	upcount = $ns	adcount = $ar
$edns
EOF

	my $aa = $self->aa;
	my $tc = $self->tc;
	my $rd = $self->rd;
	my $ra = $self->ra;
	my $zz = $self->z;
	my $ad = $self->ad;
	my $cd = $self->cd;
	my $do = $self->do;

	return $retval = <<EOF;
;;	id = $id
;;	qr = $qr	aa = $aa	tc = $tc	rd = $rd	opcode = $opcode
;;	ra = $ra	z  = $zz	ad = $ad	cd = $cd	rcode  = $rcode
;;	qdcount = $qd	ancount = $an	nscount = $ns	arcount = $ar
;;	do = $do
$edns
EOF
}

sub print { print &string; }


=head2 id

    print "query id = ", $packet->header->id, "\n";
    $packet->header->id(1234);

Gets or sets the query identification number.

A random value is assigned if the argument value is undefined.

=cut

sub id {
	my $self = shift;
	my $xpkt = $self->{xbody};
	$xpkt->{id} = shift if scalar @_;
	$xpkt->{id} ||= int rand(0xffff);
}


=head2 opcode

    print "query opcode = ", $packet->header->opcode, "\n";
    $packet->header->opcode("UPDATE");

Gets or sets the query opcode (the purpose of the query).

=cut

sub opcode {
	my $self = shift;
	my $xpkt = $self->{xbody};
	for ( $xpkt->{status} ||= 0 ) {
		return opcodebyval( ( $_ >> 11 ) & 0x0f ) unless scalar @_;
		my $opcode = opcodebyname(shift);
		$_ = ( $_ & 0x87ff ) | ( $opcode << 11 );
		return $opcode;
	}
}


=head2 rcode

    print "query response code = ", $packet->header->rcode, "\n";
    $packet->header->rcode("SERVFAIL");

Gets or sets the query response code (the status of the query).

=cut

sub rcode {
	my $self = shift;
	my $xpkt = $self->{xbody};
	for ( $xpkt->{status} ||= 0 ) {
		my $arg = shift;
		my $opt = $self->edns;
		unless ( defined $arg ) {
			return rcodebyval( $_ & 0x0f ) unless $opt->isa(qw(Net::DNS::RR::OPT));
			my $rcode = ( $opt->rcode() & 0xff0 ) | ( $_ & 0x00f );
			$opt->rcode($rcode);			# write back full 12-bit rcode
			return $rcode == 16 ? 'BADVERS' : rcodebyval($rcode);
		}
		my $rcode = rcodebyname($arg);
		$opt->rcode($rcode);				# write back full 12-bit rcode
		$_ = ( $_ & 0xfff0 ) | ( $rcode & 0x000f );
		return $rcode;
	}
}


=head2 qr

    print "query response flag = ", $packet->header->qr, "\n";
    $packet->header->qr(0);

Gets or sets the query response flag.

=cut

sub qr {
	shift->_dnsflag( 0x8000, @_ );
}


=head2 aa

    print "answer is ", $packet->header->aa ? "" : "non-", "authoritative\n";
    $packet->header->aa(0);

Gets or sets the authoritative answer flag.

=cut

sub aa {
	shift->_dnsflag( 0x0400, @_ );
}


=head2 tc

    print "packet is ", $packet->header->tc ? "" : "not ", "truncated\n";
    $packet->header->tc(0);

Gets or sets the truncated packet flag.

=cut

sub tc {
	shift->_dnsflag( 0x0200, @_ );
}


=head2 rd

    print "recursion was ", $packet->header->rd ? "" : "not ", "desired\n";
    $packet->header->rd(0);

Gets or sets the recursion desired flag.

=cut

sub rd {
	shift->_dnsflag( 0x0100, @_ );
}


=head2 ra

    print "recursion is ", $packet->header->ra ? "" : "not ", "available\n";
    $packet->header->ra(0);

Gets or sets the recursion available flag.

=cut

sub ra {
	shift->_dnsflag( 0x0080, @_ );
}


=head2 z

Unassigned bit, should always be zero.

=cut

sub z {
	shift->_dnsflag( 0x0040, @_ );
}


=head2 ad

    print "The result has ", $packet->header->ad ? "" : "not", "been verified\n";

Relevant in DNSSEC context.

(The AD bit is only set on answers where signatures have been
cryptographically verified or the server is authoritative for the data
and is allowed to set the bit by policy.)

=cut

sub ad {
	shift->_dnsflag( 0x0020, @_ );
}


=head2 cd

    print "checking was ", $packet->header->cd ? "not" : "", "desired\n";
    $packet->header->cd(0);

Gets or sets the checking disabled flag.

=cut

sub cd {
	shift->_dnsflag( 0x0010, @_ );
}


=head2 qdcount, zocount

    print "# of question records: ", $packet->header->qdcount, "\n";

Returns the number of records in the question section of the packet.
In dynamic update packets, this field is known as C<zocount> and refers
to the number of RRs in the zone section.

=cut

use vars qw($warned);

sub qdcount {
	my $self = shift;
	my $xpkt = $self->{xbody};
	return $xpkt->{count}[0] || scalar @{$xpkt->{question}} unless scalar @_;
	carp 'header->qdcount attribute is read-only' unless $warned;
}


=head2 ancount, prcount

    print "# of answer records: ", $packet->header->ancount, "\n";

Returns the number of records in the answer section of the packet
which may, in the case of corrupt packets, differ from the actual
number of records.
In dynamic update packets, this field is known as C<prcount> and refers
to the number of RRs in the prerequisite section.

=cut

sub ancount {
	my $self = shift;
	my $xpkt = $self->{xbody};
	return $xpkt->{count}[1] || scalar @{$xpkt->{answer}} unless scalar @_;
	carp 'header->ancount attribute is read-only' unless $warned;
}


=head2 nscount, upcount

    print "# of authority records: ", $packet->header->nscount, "\n";

Returns the number of records in the authority section of the packet
which may, in the case of corrupt packets, differ from the actual
number of records.
In dynamic update packets, this field is known as C<upcount> and refers
to the number of RRs in the update section.

=cut

sub nscount {
	my $self = shift;
	my $xpkt = $self->{xbody};
	return $xpkt->{count}[2] || scalar @{$xpkt->{authority}} unless scalar @_;
	carp 'header->nscount attribute is read-only' unless $warned;
}


=head2 arcount, adcount

    print "# of additional records: ", $packet->header->arcount, "\n";

Returns the number of records in the additional section of the packet
which may, in the case of corrupt packets, differ from the actual
number of records.
In dynamic update packets, this field is known as C<adcount>.

=cut

sub arcount {
	my $self = shift;
	my $xpkt = $self->{xbody};
	return $xpkt->{count}[3] || scalar @{$xpkt->{additional}} unless scalar @_;
	carp 'header->arcount attribute is read-only' unless $warned;
}

sub zocount { &qdcount; }
sub prcount { &ancount; }
sub upcount { &nscount; }
sub adcount { &arcount; }


=head1 EDNS Protocol Extensions


=head2 do

    print "DNSSEC_OK flag was ", $packet->header->do ? "not" : "", "set\n";
    $packet->header->do(1);

Gets or sets the EDNS DNSSEC OK flag.

=cut

sub do {
	shift->_ednsflag( 0x8000, @_ );
}


=head2 Extended rcode

EDNS extended rcodes are handled transparently by $packet->header->rcode().


=head2 UDP packet size

    $udp_max = $packet->edns->size;
    $udp_max = $packet->header->size;

EDNS offers a mechanism to advertise the maximum UDP packet size
which can be assembled by the local network stack.

UDP size advertisement can be viewed as either a header extension or
an EDNS feature.  Endless debate is avoided by supporting both views.

=cut

sub size {
	shift->edns->size(@_);
}


=head2 edns

    $header  = $packet->header;
    $version = $header->edns->version;
    @options = $header->edns->options;
    $option  = $header->edns->option(n);
    $udp_max = $packet->edns->size;

Auxiliary function which provides access to the EDNS protocol
extension OPT RR.

=cut

sub edns {
	my $self = shift;
	my $xpkt = $self->{xbody};
	my $link = \$xpkt->{xedns};
	($$link) = grep { $_->type eq 'OPT' } @{$xpkt->{additional}} unless $$link;
	return $$link ||= new Net::DNS::RR('. OPT');
}


########################################

use vars qw($AUTOLOAD);

sub AUTOLOAD {			## Default method
	no strict;
	@_ = ("method $AUTOLOAD undefined");
	goto &{'Carp::confess'};
}

sub DESTROY { }			## Avoid tickling AUTOLOAD (in cleanup)


sub _dnsflag {
	my $self = shift;
	my $flag = shift;
	my $xpkt = $self->{xbody};
	for ( $xpkt->{status} ||= 0 ) {
		my $set = $_ | $flag;
		my $not = $set - $flag;
		$_ = (shift) ? $set : $not if scalar @_;
		return ( $_ & $flag ) ? 1 : 0;
	}
}


sub _ednsflag {
	my $self = shift;
	my $flag = shift;
	my $edns = eval { $self->edns->flags } || 0;
	return $flag & $edns ? 1 : 0 unless scalar @_;
	my $set = $flag | $edns;
	my $not = $set - $flag;
	my $new = (shift) ? $set : $not;
	$self->edns->flags($new) unless $new == $edns;
	return ( $new & $flag ) ? 1 : 0;
}


1;
__END__


########################################

=head1 COPYRIGHT

Copyright (c)1997-2002 Michael Fuhr.

Portions Copyright (c)2002-2004 Chris Reinhardt.

Portions Copyright (c)2012 Dick Franks.

All rights reserved.

This program is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<perl>, L<Net::DNS>, L<Net::DNS::Packet>, L<Net::DNS::RR::OPT>
RFC 1035 Section 4.1.1

