use Object::Pad;

class RFC::Writer {
    use Carp 'croak';
    use File::Basename 'basename';
    use File::Spec::Functions qw(catfile catdir);
    use RFC::Config::Reader;
    use Template::Tiny::Strict;

    has $file :param;
    has $config;
    has $verbose :param = 0;
    has @toc;

    BUILD {
        unless (-e $file) {
            croak("$file does not exist");
        }
        my $reader = RFC::Config::Reader->new( file => $file );
        $config = $reader->config;
        $self->_rewrite_config;
    }

    method generate_rfcs() {
        $self->_write_readme;
        $self->_write_rfcs;
        $self->_write_toc;
    }

    method _write_toc () {
        my $toc_file = $config->{rfcs}[0]{file}; # toc is always first
        my $toc_list = join "\n" => @toc;
        my $file_contents = $self->_slurp($toc_file);
        my $marker = $config->{main}{toc_marker};
        unless ($file_contents =~ /\Q$marker\E/) {
            croak("TOC marker '$marker' not found in toc file: $toc_file");
        }
        $file_contents =~ s/\Q$marker\E/$toc_list/;
        $self->_splat($toc_file, $file_contents);
    }

    method _write_readme () {
        my $readme_template = $config->{main}{readme_template};
        my $readme          = $config->{main}{readme};
        print "Processing $readme_template\n" if $verbose;
        my $tts = Template::Tiny::Strict->new(
            forbid_undef  => 1,
            forbid_unused => 1,
            name          => 'README',
        );
        my $template = $self->_slurp($readme_template);
        $tts->process(
            \$template,
            {
                templates => $config->{rfcs},
                config    => $config->{main},
            },
            \my $out,
        );
        $self->_splat( $readme, $out );
    }

    method _write_rfcs {
        my $rfcs    = $config->{rfcs};
        my $default = { name => 'README', basename => '/README.md' };
        foreach my $i ( 0 .. $#$rfcs ) {
            my $prev = $i > 0 ? $rfcs->[ $i - 1 ] : $default;
            my $rfc  = $rfcs->[$i];
            my $next = $rfcs->[ $i + 1 ] || $default;

            my $file = $rfc->{file};
            print "Processing $rfc->{source}\n" if $verbose;
            my $tts = Template::Tiny::Strict->new(
                forbid_undef  => 1,
                forbid_unused => 1,
            );
            my $template = $self->_get_rfc_template($rfc);
            $tts->process(
                \$template,
                {
                    prev   => $prev,
                    rfc    => $rfc,
                    next   => $next,
                    config => $config->{main},
                },
                \my $out
            );
            $self->_splat( $file, $out );
        }
    }

    method _rewrite_config() {
        my $rfcs            = $config->{rfcs};
        my $readme_template = $config->{main}{readme}
          or die "No readme found in [main] for config";
        my $toc_template = $config->{main}{toc}
          or die "No toc found in [main] for config";
        $self->_assert_template_name( $readme_template,
            $config->{main}{template_dir} );
        $config->{main}{readme_template} =
          catfile( $config->{main}{template_dir}, $readme_template );
        $config->{main}{toc_template} =
          catfile( $config->{main}{template_dir}, $config->{main}{rfc_dir}, $toc_template );
        

        my $index = 1;

        unshift @$rfcs => {
            key   => 'Table of Contents',
            value => $config->{main}{toc},
        };

        foreach my $rfc (@$rfcs) {
            my $filename = $rfc->{value};
            $self->_assert_template_name(
                $filename,
                $config->{main}{template_dir},
                $config->{main}{rfc_dir}
            );
            delete $rfc->{value};
            $rfc->{name}   = delete $rfc->{key};
            $rfc->{source} = catfile( $config->{main}{template_dir},
                $config->{main}{rfc_dir}, $filename );
            $rfc->{file}     = catfile( $config->{main}{rfc_dir}, $filename );
            $rfc->{basename} = $filename;
            $rfc->{index}    = $index;
            $index++;
        }
    }

    method _assert_template_name ( $filename, @dirs ) {
        unless ( $filename =~ /\.md$/ ) {
            croak("Template filename must end in '.md': $filename");
        }
        my $location = catfile( @dirs, $filename );
        unless ( -e $location ) {
            croak("Template '$location' does not exist");
        }
    }

    method _get_rfc_template ($rfc) {
        my $template = $self->_renumbered_headings($rfc);
        return <<"END";
Prev: [[% prev.name %]]([% prev.basename %])   
Next: [[% next.name %]]([% next.basename %])

---

# Section [% rfc.index %]: [% rfc.name %]

**This file is automatically generated. If you wish to submit a PR, do not
edit this file directly. Please edit
[[% rfc.source %]]([% config.github %]/tree/master/[% rfc.source %]) instead.**

---

$template

---

Prev: [[% prev.name %]]([% prev.basename %])   
Next: [[% next.name %]]([% next.basename %])
END
    }

    method _renumbered_headings ($rfc) {
        my $template = $self->_slurp( $rfc->{source} );

        push @toc => "\n# [Section: $rfc->{index}: $rfc->{name}]($rfc->{file})\n";

        # XXX fix me. Put this in config
        return $template if $rfc->{name} eq 'Changes';

        my $rewritten = '';
        my @lines     = split /\n/ => $template;

        my %levels = map { $_ => 0 } 1 .. 4;

        my $last_level = 1;

        my $in_code = 0;
    LINE: foreach my $line (@lines) {
            if ( $line =~ /^```/ ) {
                if ( !$in_code ) {
                    $in_code = 1;
                }
                else {
                    $in_code = 0;
                }
                $rewritten .= "$line\n";
            }
            elsif ( $line =~ /^(#+)\s+(.*)/ && !$in_code ) {
                my $hashes = $1;
                my $title  = $2;
                my $level  = length $hashes;
                if ( $last_level == $level ) {

                    # ## 1.2
                    # ## 1.3
                    $levels{$level}++;
                }
                elsif ( $last_level < $level ) {

                    # #
                    # ##
                    $levels{$level} = 1;
                }
                else {
                    # ##
                    # #
                    $levels{1}++;
                    for my $i ( 2 .. $level ) {
                        $levels{$i} = 1;
                    }
                }
                $last_level = $level;
                if ( $levels{1} == 0 ) {
                    croak("$rfc->{source} didn't start with a level 1 header");
                }
                my $section_num = join '.' => $rfc->{index},
                map { $levels{$_} } 1 .. $level;
                my $num_dots = $section_num =~ tr/\././;
                my $leader = $num_dots ? '..' x $num_dots : '';
                push @toc => "* `$leader` $section_num $title";
                $rewritten .= "$hashes $section_num $title";
            }
            else {
                $rewritten .= "$line\n";
            }
        }
        return $rewritten;
    }

    method _slurp($file) {
        open my $fh, '<', $file or die "Cannot open $file for reading: $!";
        return do { local $/; <$fh> };
    }

    method _splat( $file, $data ) {
        if ( ref $data ) {
            croak("Data for splat '$file' must not be a reference ($data)");
        }
        open my $fh, '>', $file or die "Cannot open $file for writing: $!";
        print {$fh} $data;
    }
}
