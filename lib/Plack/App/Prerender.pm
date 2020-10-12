package Plack::App::Prerender;

use v5.10;
use strict;
use warnings;

use parent qw/ Plack::Component /;

use Crypt::Digest qw/ digest_data /;
use Encode qw/ encode /;
use HTTP::Headers;
use HTTP::Request;
use HTTP::Status qw/ :constants /;
use Log::Log4perl qw/ :easy /;
use Plack::Util;
use Plack::Util::Accessor qw/ mech base cache max_age digest headers /;
use Time::Seconds qw/ ONE_HOUR /;
use WWW::Mechanize::Chrome;

sub prepare_app {
    my ($self) = @_;

    Log::Log4perl->easy_init($ERROR);

    unless ($self->mech) {

        my $mech = WWW::Mechanize::Chrome->new(
            headless         => 1,
            separate_session => 1,
            launch_arg => [qw/ --start-maximized /],
        );

        $self->mech($mech);

    }

    unless ($self->headers) {
        $self->headers(
            [
             qw/
             Content-Encoding
             Content-Length
             Content-Type
             Expires
             Last-Modified
             /
            ]
        );
    }

    unless ($self->max_age) {
        $self->max_age( ONE_HOUR );
    }
}

sub call {
    my ($self, $env) = @_;

    my $method = $env->{REQUEST_METHOD} // '';
    unless ($method eq "GET") {
        return [ HTTP_METHOD_NOT_ALLOWED ];
    }

    my $path_query = $env->{REQUEST_URI};
    my $key = digest_data( $self->digest || 'SHA1', $path_query );

    my $cache = $self->cache;

    my $data  = $cache->get($key);
    if (defined $data) {

        return $data;

    }
    else {

        my $mech = $self->mech;
        $mech->reset_headers;

        # TODO pass through some request headers

        my $res  = $mech->get( $self->base . $path_query );
        my $body = encode("UTF-8", $mech->content);

        my $head = $res->headers;
        my $h = Plack::Util::headers([ 'X-Renderer' => __PACKAGE__ ]);
        for my $field (@{ $self->headers }) {
            my $value = $head->header($field) // next;
            $value =~ tr/\n/ /;
            $h->set( $field => $value );
        }

        if ($res->code == HTTP_OK) {

            my $age;
            if (my $value = $head->header("Cache-Control")) {
                ($age) = $value =~ /(?:s\-)?max-age=([0-9]+)\b/;
            }

            $data = [ HTTP_OK, $h->headers, [$body] ];

            $cache->set( $key, $data, $age // $self->max_age );

            return $data;

        }
        else {

            return [ $res->code, $h->headers, [$body] ];

        }
    }

}

1;
