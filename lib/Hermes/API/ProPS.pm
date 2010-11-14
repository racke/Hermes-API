package Hermes::API::ProPS;

use strict;
use warnings;

use Locale::Geocode;
use SOAP::Lite +trace => [transport => \&log_request];
#use SOAP::Lite +trace => 'all';
	
our %parms = (# Hermes::API authentication
			  PartnerId => undef,
			  PartnerPwd => undef,

			  # Module parameters
			  SandBox => 0,

			  SandBoxHost => 'sandboxapi.hlg.de',
			  ProductionHost => 'hermesapi2.hlg.de',
			  APIVersion => '1.2');

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
	
	# check for required parameters: PartnerID and PartnerPwd
	while (@args) {
		$key = shift @args;
		$value = shift @args;

		if (exists $parms{$key}) {
			$self->{$key} = $value;
		}
		else {
			return;
		}
	}

	# finally build URL
	$self->{url} = $self->build_url();

	# instantiate SOAP::Lite
	$self->{soap} = new SOAP::Lite(proxy => $self->{url});

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
	
	$ret = $self->ProPS('propsUserLogin', $soap_params);

	# set user token for further requests
	$self->{UserToken} = $ret;
}

sub OrderSave {
	my ($self, $address) = @_;
	my ($soap_params, $ret);
	
	$soap_params = $self->order_parameters($address);
	
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

	if (@params) {
		print "Data for $service: ", $params[0]->name(), "\n";
	}
	
	$ret = $self->{soap}->call($service, @params, @headers);

	if ($@) {
		die $@;
	}
	
	if ($ret->fault()) {
		my ($detail);

		use Data::Dumper;
		
		$detail = $ret->faultdetail();

		if ($detail) {
			# check for service exception
			if (exists $detail->{ServiceException}) {
				die "Service Exception: " . Dumper($detail->{ServiceException}->{exceptionItems});
			}
		}

		die sprintf("SOAP Fault: %s (%s)\n", $ret->faultcode(), $ret->faultstring());
	}

	# pick up PartnerToken from response header
	$self->{PartnerToken} = $ret->header()->{PartnerToken};

	return $ret->result();
}

sub order_parameters {
	my ($self, $address) = @_;
	my ($input, @address_parms);

	# country code conversion
	if (exists $address->{countryCode} && length($address->{countryCode}) == 2) {
		my ($lc, $lct) = @_;
		
		$lc = new Locale::Geocode;
		unless ($lct = $lc->lookup($address->{countryCode})) {
			die "Invalid country code $address->{countryCode}\n";
		}
		$address->{countryCode} = $lct->alpha3;
	}
		
	for (qw/firstname lastname street houseNumber addressAdd postcode city district countryCode email telephoneNumber telephonePrefix/) {
		if (exists $address->{$_} && $address->{$_} =~ /\S/) {
			push(@address_parms, $_, $address->{$_});
		}
	}

	$input = [propsOrder => [receiver => \@address_parms]];

	return $self->soap_parameters($input);
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

sub log_request {
	my ($in) = @_;
	
    if (ref($in) eq "HTTP::Request") {
		# do something...
		print $in->as_string; # ...for example
    } elsif (ref($in) eq "HTTP::Response") {
		# do something
		print $in->as_string;
    }
}

1;
