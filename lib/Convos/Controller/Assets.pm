package Convos::Controller::Assets;

sub upload {
  my $self = shift->openapi->valid_input or return;

  return $self->assets->upload_p()->then(
    sub {
    }
  );
}

1;
