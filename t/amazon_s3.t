use strict;
use warnings;

require 't/test_helpers.inc.pl';

# NoWarnings test fails because of Net::Amazon::S3:
#
#     Passing a list of values to enum is deprecated. Enum values should be
#     wrapped in an arrayref. at /System/Library/Perl/Extras/5.18/darwin-thread
#     -multi-2level/Moose/Util/TypeConstraints.pm line 442.
#
# use Test::NoWarnings;

use Test::More;
use Test::Deep;

if ( s3_test_configuration_is_set() )
{
    plan tests => 42;
}
else
{
    plan skip_all => "S3 test configuration is not set in the environment.";
}

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";

    use CopyKVS::Handler::AmazonS3;
    use Net::Amazon::S3;
}

# Connection configuration
my $config = configuration_from_env();

# Randomize directory name so that multiple tests could run concurrently
$config->{ connectors }->{ "amazon_s3_test" }->{ directory_name } .= '-' . random_string( 16 );

# Create temporary bucket for unit tests
my $s3_connector = $config->{ connectors }->{ "amazon_s3_test" };
say STDERR "Creating temporary bucket '$s3_connector->{ bucket_name }'...";
my $native_s3 = Net::Amazon::S3->new(
    {
        aws_access_key_id     => $s3_connector->{ access_key_id },
        aws_secret_access_key => $s3_connector->{ secret_access_key },
        retry                 => 1,
    }
);
my $test_bucket = $native_s3->add_bucket( { bucket => $s3_connector->{ bucket_name } } )
  or die $native_s3->err . ": " . $native_s3->errstr;

# Instances with / without directory name
my $s3_with_directory = CopyKVS::Handler::AmazonS3->new(
    access_key_id     => $s3_connector->{ access_key_id },
    secret_access_key => $s3_connector->{ secret_access_key },
    bucket_name       => $s3_connector->{ bucket_name },
    directory_name    => $s3_connector->{ directory_name }
);
my $s3_without_directory = CopyKVS::Handler::AmazonS3->new(
    access_key_id     => $s3_connector->{ access_key_id },
    secret_access_key => $s3_connector->{ secret_access_key },
    bucket_name       => $s3_connector->{ bucket_name },
    directory_name    => ''
);

sub run_tests($$)
{
    my ( $s3, $description ) = @_;

    my $test_filename = 'xyz';
    my $test_content;
    my $returned_content;

    # Store, fetch content
    $test_content = 'Loren ipsum dolor sit amet.';
    ok( $s3->put( $test_filename, $test_content ), "Storing filename '$test_filename' did not return true ($description)" );
    ok( $s3->head( $test_filename ), "head() does not report that the file exists" );
    ok( $returned_content = $s3->get( $test_filename ),
        "Getting filename '$test_filename' did not return contents ($description)" );
    is( $test_content, $returned_content, "Content doesn't match" );
    ok( $s3->delete( $test_filename ), "Deleting filename '$test_filename' did not return true ($description)" );
    ok( !$s3->head( $test_filename ),  "head() reports that the file that was just removed still exists" );

    # Store content twice
    $test_content = 'Loren ipsum dolor sit amet.';
    ok( $s3->put( $test_filename, $test_content ), "Storing filename '$test_filename' did not return true ($description)" );
    ok( $s3->put( $test_filename, $test_content ),
        "Storing filename '$test_filename' the second time did not return true ($description)" );
    ok( $s3->head( $test_filename ), "head() does not report that the file exists" );
    ok( $returned_content = $s3->get( $test_filename ),
        "Getting filename '$test_filename' did not return contents ($description)" );
    is( $test_content, $returned_content, "Content doesn't match" );
    ok( $s3->delete( $test_filename ), "Deleting filename '$test_filename' did not return true ($description)" );
    ok( !$s3->head( $test_filename ),  "head() reports that the file that was just removed still exists" );

    # Store, fetch empty file
    $test_content = '';
    ok( $s3->put( $test_filename, $test_content ),
        "Storing filename '$test_filename' without contents did not return true ($description)" );
    ok( $s3->head( $test_filename ), "head() does not report that the file exists" );
    $returned_content = $s3->get( $test_filename );
    ok( defined( $returned_content ), "Getting filename '$test_filename' did not return contents ($description)" );
    is( $test_content, $returned_content, "Content doesn't match" );
    ok( $s3->delete( $test_filename ), "Deleting filename '$test_filename' did not return true ($description)" );
    ok( !$s3->head( $test_filename ),  "head() reports that the file that was just removed still exists" );

    # Try fetching nonexistent filename
    eval { $s3->get( 'does-not-exist' ); };
    ok( $@,                           "Fetching file that does not exist should have failed" );
    ok( !$s3->head( $test_filename ), "head() does not report that the nonexistent file exists" );

}

# Run tests for both buckets
run_tests( $s3_with_directory,    'with directory' );
run_tests( $s3_without_directory, 'without directory' );

