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
    plan tests => 3;
}
else
{
    plan skip_all => "S3 test configuration is not set in the environment.";
}

use Data::Dumper;
use Readonly;

Readonly my $NUMBER_OF_TEST_FILES => 10;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";

    use CopyKVS;
    use CopyKVS::Handler::GridFS;
    use Net::Amazon::S3;
    use MongoDB;
}

# Connection configuration
my $config = configuration_from_env();

# Randomize directory name so that multiple tests could run concurrently
$config->{ connectors }->{ "amazon_s3_test" }->{ directory_name } .= '-' . random_string( 16 );

# Create temporary bucket for unit tests
my $mongodb_connector = $config->{ connectors }->{ "mongodb_gridfs_test" };
my $s3_connector      = $config->{ connectors }->{ "amazon_s3_test" };

my $native_s3 = Net::Amazon::S3->new(
    {
        aws_access_key_id     => $s3_connector->{ access_key_id },
        aws_secret_access_key => $s3_connector->{ secret_access_key },
        retry                 => 1,
    }
);
my $test_bucket = $native_s3->add_bucket( { bucket => $s3_connector->{ bucket_name } } )
  or die $native_s3->err . ": " . $native_s3->errstr;

# Create temporary databases for unit tests
my $native_mongo_client = MongoDB::MongoClient->new(
    host => $mongodb_connector->{ host },
    port => $mongodb_connector->{ port }
);

# Should auto-create on first write
my $test_source_database_name = $mongodb_connector->{ database } . '_src_' . random_string( 16 );
say STDERR "Source database name: $test_source_database_name";
my $native_source_mongo_database = $native_mongo_client->get_database( $test_source_database_name );
my $gridfs_source                = CopyKVS::Handler::GridFS->new(
    host     => $mongodb_connector->{ host },
    port     => $mongodb_connector->{ port },
    database => $test_source_database_name
);

my $test_destination_database_name = $mongodb_connector->{ database } . '_dst_' . random_string( 16 );
say STDERR "Destination database name: $test_destination_database_name";
my $native_destination_mongo_database = $native_mongo_client->get_database( $test_destination_database_name );
my $gridfs_destination                = CopyKVS::Handler::GridFS->new(
    host     => $mongodb_connector->{ host },
    port     => $mongodb_connector->{ port },
    database => $test_destination_database_name
);

# Create test files
my @files_src;
for ( my $x = 0 ; $x < $NUMBER_OF_TEST_FILES ; ++$x )
{
    push( @files_src, { filename => 'file-' . random_string( 32 ), contents => random_string( 128 ) } );
}

# Store files into the source GridFS database
for my $file ( @files_src )
{
    $gridfs_source->put( $file->{ filename }, $file->{ contents } );
}

# Copy files from source GridFS database to S3
$config->{ connectors }->{ "mongodb_gridfs_test" }->{ database } = $test_source_database_name;
ok( CopyKVS::copy_kvs( $config, "mongodb_gridfs_test", "amazon_s3_test" ), "Copy from source GridFS to S3" );

# Copy files back from S3 to GridFS
$config->{ connectors }->{ "mongodb_gridfs_test" }->{ database } = $test_destination_database_name;
ok( CopyKVS::copy_kvs( $config, "amazon_s3_test", "mongodb_gridfs_test" ), "Copy from S3 to destination GridFS" );

# Delete temporary bucket and databases, remove "last filename" files
my $response = $test_bucket->list_all( { prefix => $s3_connector->{ directory_name } } );
foreach my $key ( @{ $response->{ keys } } )
{
    say STDERR "Removing temporary file " . $key->{ key } . "...";
    $test_bucket->delete_key( $key->{ key } );
}
unlink $config->{ connectors }->{ "mongodb_gridfs_test" }->{ last_copied_file };
unlink $config->{ connectors }->{ "amazon_s3_test" }->{ last_copied_file };

my @files_dst;

my @dst_files_list = $native_destination_mongo_database->get_gridfs->all();
foreach my $file ( @dst_files_list )
{
    $file = {
        filename => $file->info->{ 'filename' },
        contents => $file->slurp,
    };
    push( @files_dst, $file );
}

# Compare files between source and destination GridFS databases
cmp_bag( \@files_dst, \@files_src,
    'List of files and their contents match; got: ' . Dumper( \@files_dst ) . '; expected: ' . Dumper( \@files_src ) );

$native_source_mongo_database->drop;
$native_destination_mongo_database->drop;
