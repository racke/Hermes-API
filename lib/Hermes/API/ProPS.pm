# Hermes::API::ProPS - Hermes API ProPS shipping module
#
# Copyright 2010 by Stefan Hornburg (Racke) <racke@linuxia.de>

package Hermes::API::ProPS;

use strict;
use warnings;

use Log::Dispatch;

use Locale::Geocode;
use SOAP::Lite;

use DateTime;
use IO::File;
use MIME::Base64;

our %parms = (# Hermes::API authentication
			  PartnerId => undef,
			  PartnerPwd => undef,
			  PartnerToken => undef,
			  UserToken => undef,

			  # Module parameters
			  SandBox => 0,

			  SandBoxHost => 'sandboxapi.hlg.de',
			  ProductionHost => 'hermesapi2.hlg.de',
			  APIVersion => '1.2',

			  # Debug/logging
			  Trace => undef,
			 );

sub new {
	my ($class, $self);

	$class = shift;
	
	$self = {};
	bless ($self, $class);

	unless ($self->initialize(@_)) {
		die "Invalid parameters for Hermes::API::ProPS\n";
	}

	return $self;
}

sub initialize {
	my ($self, @args) = @_;
	my ($key, $value);

	# defaults
	for (keys %parms) {
		if (defined $parms{$_}) {
			$self->{$_} = $parms{$_};
		}
	}
	
	# check for required parameters: PartnerId and PartnerPwd
	while (@args) {
		$key = shift @args;
		$value = shift @args;

		if (exists $parms{$key}) {
			$self->{$key} = $value;
		}
	}

	unless (defined $self->{PartnerId} && defined $self->{PartnerPwd}) {
		die "PartnerId and PartnerPwd parameters required for Hermes::API::ProPS objects.\n";
	}

	# log dispatcher
	my @outputs;

	@outputs = (['Screen', min_level => 'debug']);
	
	$self->{log} = new Log::Dispatch(outputs => \@outputs);
	
	# finally build URL
	$self->{url} = $self->build_url();

	# instantiate SOAP::Lite
	$self->{soap} = new SOAP::Lite(proxy => $self->{url});

	if ($self->{Trace}) {
		my $request_sub = sub {$self->log_request(@_)};
		$self->{soap}->import(+trace => [transport => $request_sub]);		
	}
	
	return 1;		
}

sub url {
	my ($self) = @_;

	return $self->{url};
}

sub CheckAvailability {
	my ($self) = @_;

	$self->ProPS('propsCheckAvailability');
}

sub UserLogin {
	my ($self, $username, $password) = @_;
	my ($input_params, $soap_params, $ret);

	$input_params = ['login' => ['benutzername' => $username,
								 'kennwort' => $password]];

	$soap_params = $self->soap_parameters($input_params);
	
	if ($ret = $self->ProPS('propsUserLogin', $soap_params)) {
		# set user token for further requests
		$self->{UserToken} = $ret;
	}

	return $ret;
}

sub OrderSave {
	my ($self, $address, %extra) = @_;
	my ($soap_params, $ret);
	
	$soap_params = $self->order_parameters($address, %extra);
	
	$ret = $self->ProPS('propsOrderSave', $soap_params);

	return $ret;
}

sub OrderDelete {
	my ($self, $order_number) = @_;
	my ($input_params, $soap_params, $ret);
	
	unless ($self->{UserToken}) {
		die "UserToken required for OrderDelete service.\n";
	}

	$input_params = ['orderNo' => {value => $order_number, type => 'string'}];
	$soap_params = $self->soap_parameters($input_params);

	$ret = $self->ProPS('propsOrderDelete', $soap_params);

	return $ret;
}

sub GetOrder {
	my ($self, %parms) = @_;
	my ($input_params, $soap_params, $ret);
	
	unless ($self->{UserToken}) {
		die "UserToken required for GetOrder service.\n";
	}

	$input_params = ['orderNo' => {value => $parms{orderNo},
								   type => 'string'},
					 'shippingId' => {value => $parms{shippingId},
									  type => 'string'},
					];
	$soap_params = $self->soap_parameters($input_params);

	$ret = $self->ProPS('propsGetPropsOrder', $soap_params);
	
	return $ret;
}

sub GetOrders {
	my ($self, $search) = @_;
	my ($input_params, $soap_params, $ret, $orders);
	
	unless ($self->{UserToken}) {
		die "UserToken required for GetOrders service.\n";
	}
	
	$soap_params = $self->search_parameters($search);

	if ($ret = $self->ProPS('propsGetPropsOrders', $soap_params)) {
		$orders = $ret->{orders}->{PropsOrderShort};

		if (! defined $orders) {
			# no matches
			return[];
		}
		elsif (ref($orders) eq 'HASH') {
			# we get hash reference for single matches
			return [$orders];
		}
		else {
			return $orders;
		}
	}

	return;
}

sub PrintLabel {
	my ($self, $order_number, $format, $position, $output) = @_;
	my ($service, $input_params, $soap_params, $output_param, $ret);
	
	if ($format eq 'PDF') {
		$service = 'propsOrderPrintLabelPdf';
		$input_params = [orderNo => {value => $order_number, type => 'string'},
						 position => ($position || 1)];
		$output_param = 'pdfData';
	}
	elsif ($format eq 'JPEG') {
		$service = 'propsOrderPrintLabelJpeg';
		$input_params = [orderNo => {value => $order_number, type => 'string'}];
		$output_param = 'jpegData';
	}

	$soap_params = $self->soap_parameters($input_params);
	
	unless ($self->{UserToken}) {
		die "UserToken required for GetOrders service.\n";
	}

	$ret = $self->ProPS($service, $soap_params);

	if ($ret && $output) {
		my ($fh, $data);
		
		$fh = new IO::File "> $output";
		$data = MIME::Base64::decode_base64($ret->{$output_param});

		print $fh $data;

		$fh->close;
	}
	
	return $ret->{$output_param};
}

sub CollectionRequest {
	my ($self, $date, %parcel_counts) = @_;
	my (@request_parms, $soap_params, $name, $count, $ret);

	push (@request_parms, collectionDate => $date);

	# parameters for collection request
	for (qw/XS S M L XL XXL/) {
		$name = "numberOfParcelsClass_$_";

                if (exists $parcel_counts{$_}) {
			$count = $parcel_counts{$_};
		}
		else {
			$count = 0;
		}

		push (@request_parms, $name, $count);
	}
 
	unless ($self->{UserToken}) {
                die "UserToken required for CollectionRequest service.\n";
        }

	$soap_params = $self->soap_parameters([collectionOrder => \@request_parms]);

        if ($ret = $self->ProPS('propsCollectionRequest', $soap_params)) {
		return $ret;
	}

	return;
}

sub CollectionCancel {
	my ($self, $date) = @_;
	my ($soap_params, $ret);

	unless ($self->{UserToken}) {
                die "UserToken required for CollectionCancel service.\n";
        }

	$soap_params = $self->soap_parameters([collectionDate => $date]);

	if ($ret = $self->ProPS('propsCollectionCancel', $soap_params)) {
                return $ret;
        }

        return;
}

sub GetCollectionOrders {
	my ($self, $date_from, $date_to, $large) = @_;
	my (@collection_params, $soap_params, $orders, $ret);

	unless ($date_from) {
		$date_from = DateTime->now()->iso8601();
	}

	unless ($date_to) {
		$date_to = DateTime->now()->add(months => 3)->iso8601();
	}

	unless (defined $large) {
		$large = 0;
	}

	@collection_params = (collectionDateFrom => $date_from,
						  collectionDateTo => $date_to,
						  onlyMoreThan2ccm => $large);

	$soap_params = $self->soap_parameters(\@collection_params);

	unless ($self->{UserToken}) {
		die "UserToken required for GetOrders service.\n";
	}
	
	if ($ret = $self->ProPS('propsGetCollectionOrders', $soap_params)) {
		$orders = $ret->{orders}->{PropsCollectionOrderLong};

		if (! defined $orders) {
			# no matches
			return[];
		}
		elsif (ref($orders) eq 'HASH') {
			# we get hash reference for single matches
			return [$orders];
		}
		else {
			return $orders;
		}
	}

	return;
}

sub ReadShipmentStatus {
	my ($self, $shipid) = @_;
	my ($soap_params, $ret);

	$soap_params = $self->soap_parameters([shippingId => {value => $shipid, type => 'string'}]);

	if ($ret = $self->ProPS('propsReadShipmentStatus', $soap_params)) {
		return $ret;
	}
}

sub ProductInformation {
	my ($self) = @_;
	my ($ret);
	
	$ret = $self->ProPS('propsProductlnformation');

	return $ret;
}

sub ListOfProductsATG {
	my ($self) = @_;
	my ($ret);

	unless ($self->{UserToken}) {
		die "UserToken required for ListOfProductsATG service.\n";
	}
	
	$ret = $self->ProPS('propsListOfProductsATG');

	return $ret;
	
}

sub ProPS {
	my ($self, $service, @params) = @_;
	my ($ret, @headers);

	# build SOAP headers
	@headers = $self->soap_header();

	$ret = $self->{soap}->call($service, @params, @headers);

	if ($@) {
		die $@;
	}
	
	if ($ret->fault()) {
		my ($detail, $item);
		
		$detail = $ret->faultdetail();

		if ($detail) {
			# check for service exception
			if (exists $detail->{ServiceException}->{exceptionItems}->{ExceptionItem}) {
				$item = $detail->{ServiceException}->{exceptionItems}->{ExceptionItem};

				$self->set_error($item);
				return;
			}
			use Data::Dumper;
			print Dumper($detail);
		}

		die sprintf("SOAP Fault: %s (%s)\n", $ret->faultcode(), $ret->faultstring());
	}
	else {
		$self->clear_error();
	}

	# pick up PartnerToken from response header
	$self->{PartnerToken} = $ret->header()->{PartnerToken};

	return $ret->result();
}

sub search_parameters {
	my ($self, $search) = @_;
	my ($input, @search_parms, %address_parms);
	
	# country code conversion
	if (ref($search) eq 'HASH' && exists $search->{countryCode}) {
		$search->{countryCode} = $self->country_alpha3($search->{countryCode});
	}

	%address_parms = (lastname => 1, city => 1);
	
	for (qw/orderNo identNo from to lastname city postcode countryCode clientReferenceNumber ebayNumber status/) {
		if (exists $search->{$_} && $search->{$_} =~ /\S/) {
			if (exists $address_parms{$_}) {
				# force type to "string" in order to avoid base64 encoding
				push(@search_parms, $_, {value => $search->{$_}, type => 'string'});
			}
			else {
				push(@search_parms, $_, $search->{$_});
			}
		}
	}

	$input = [searchCriteria => \@search_parms];
	
	return $self->soap_parameters($input);	
}

sub order_parameters {
	my ($self, $address, %extra) = @_;
	my ($input, @address_parms, @order_parms);

	# country code conversion
	$address->{countryCode} = $self->country_alpha3($address->{countryCode});
		
	for (qw/firstname lastname street houseNumber addressAdd postcode city district countryCode email telephoneNumber telephonePrefix/) {
		if (exists $address->{$_} && $address->{$_} =~ /\S/) {
			# force type to "string" in order to avoid base64 encoding
			push(@address_parms, $_, {value => $address->{$_}, type => 'string'});
		}
	}

	$extra{receiver} = \@address_parms;

	for (qw/orderNo receiver clientReferenceNumber parcelClass amountCashOnDelivery includeCashOnDelivery/) {
		if (exists $extra{$_}) {
			push (@order_parms, $_, $extra{$_});
		}
	}
		
	$input = [propsOrder => \@order_parms];

	return $self->soap_parameters($input);
}

sub country_alpha3 {
	my ($self, $code) = @_;
	my ($lc, $lct) = @_;

	if ($code && length($code) == 2) {
		$lc = new Locale::Geocode;

		unless ($lct = $lc->lookup($code)) {
			die "Invalid country code $code\n";
		}

		$code = $lct->alpha3;
	}

	return $code;
}

sub build_url {
	my ($self) = @_;
	my ($url, $host, $version_part);

	$version_part = $self->{APIVersion};
	$version_part =~ s/\./_/g;

	if ($self->{SandBox}) {
		$host = $self->{SandBoxHost};
	}
	else {
		$host = $self->{ProductionHost};
	}

	$url = "https://$host/Hermes_API_Web/$version_part/services/ProPS";

	return $url;	
}

sub soap_header {
	my ($self) = @_;
	my (@headers);
	
	for (qw/PartnerId PartnerPwd PartnerToken UserToken/) {
		if (exists $self->{$_}) {
			push(@headers, SOAP::Header->name($_)->value($self->{$_}));
		}
	}

	return @headers;
}

sub soap_parameters {
	my ($self, $input, $level) = @_;
	my ($key, $value, @params);

	$level ||= 0;

	if (@$input > 2 && $level == 0) {
		# build XML string and pass to SOAP::Data
		my $xml;
		
		for (my $i = 0; $i < @$input; $i += 2) {
			$key = $input->[$i];
			$value = $input->[$i+1];

			if (ref($value) eq 'HASH') {
				$xml .= qq{<$key>$value->{value}</$key>};
			}
			else {
				$xml .= qq{<$key>$value</$key>};
			}
		}

		return SOAP::Data->type(xml => $xml);
	}
	
	for (my $i = 0; $i < @$input; $i += 2) {
		$key = $input->[$i];
		$value = $input->[$i+1];

		if (ref($value) eq 'ARRAY') {
			push (@params, SOAP::Data->name($key => $self->soap_parameters($value, $level + 1)));
		}
		elsif (ref($value) eq 'HASH') {
			# forcing SOAP type
			push (@params, SOAP::Data->name($key => $value->{value})->type($value->{type}));
		}
		else {
			push (@params, SOAP::Data->name($key => $value));
		}
	}

	if (! $level) {
		return $params[0];
	}
	else {
		return \SOAP::Data->value(@params);
	}
}

# error handling
sub set_error {
	my ($self, $item) = @_;

	$self->{error} = $item;
}

sub clear_error {
	my ($self) = @_;

	delete $self->{error};
}

sub get_error {
	my ($self) = @_;
	
    if ($self->{error}) {
		return $self->{error}->{errorMessage};
	}
}

sub log_request {
	my ($self, $in) = @_;
	
    if (ref($in) eq "HTTP::Request") {
		# do something...
		$self->{log}->debug($in->as_string);
    } elsif (ref($in) eq "HTTP::Response") {
		# do something
		$self->{log}->debug($in->as_string);
    }
}

1;
