require 'ruby-audio'
require 'ruby-sox'
require 'oily_png'
require 'fileutils'

module CarrierWave
  module AudioWaveform
    class Waveformer
      DefaultOptions = {
        :method => :peak,
        :width => 1800,
        :height => 280,
        :background_color => "#666666",
        :color => "#00ccff",
        :logger => nil,
        :type => :png
      }

      TransparencyMask = "#00ff00"
      TransparencyAlternate = "#ffff00" # in case the mask is the background color!

      attr_reader :source

      # Scope these under Waveform so you can catch the ones generated by just this
      # class.
      class RuntimeError < ::RuntimeError;end;
      class ArgumentError < ::ArgumentError;end;

      class << self
        # Generate a Waveform image at the given filename with the given options.
        #
        # Available options (all optional) are:
        #
        #   :method => The method used to read sample frames, available methods
        #     are peak and rms. peak is probably what you're used to seeing, it uses
        #     the maximum amplitude per sample to generate the waveform, so the
        #     waveform looks more dynamic. RMS gives a more fluid waveform and
        #     probably more accurately reflects what you hear, but isn't as
        #     pronounced (typically).
        #
        #     Can be :rms or :peak
        #     Default is :peak.
        #
        #   :width => The width (in pixels) of the final waveform image.
        #     Default is 1800.
        #
        #   :height => The height (in pixels) of the final waveform image.
        #     Default is 280.
        #
        #   :auto_width => msec per pixel. This will overwrite the width of the
        #     final waveform image depending on the length of the audio file.
        #     Example:
        #       100 => 1 pixel per 100 msec; a one minute audio file will result in a width of 600 pixels
        #
        #   :background_color => Hex code of the background color of the generated
        #     waveform image. Pass :transparent for transparent background.
        #     Default is #666666 (gray).
        #
        #   :color => Hex code of the color to draw the waveform, or can pass
        #     :transparent to render the waveform transparent (use w/ a solid
        #     color background to achieve a "cutout" effect).
        #     Default is #00ccff (cyan-ish).
        #
        #   :sample_width => Integer specifying the sample width. If this
        #     is specified, there will be gaps (minimum of 1px wide, as specified
        #     by :gap_width) between samples that are this wide in pixels.
        #     Default is nil
        #     Minimum is 1 (for anything other than nil)
        #
        #   :gap_width => Integer specifying the gap width. If sample_width
        #     is specified, this will be the size of the gaps between samples in pixels.
        #     Default is nil
        #     Minimum is 1 (for anything other than nil, or when sample_width is present but gap_width is not)
        #
        #   :logger => IOStream to log progress to.
        #
        # Example:
        #   CarrierWave::AudioWaveform::Waveformer.generate("Kickstart My Heart.wav")
        #   CarrierWave::AudioWaveform::Waveformer.generate("Kickstart My Heart.wav", :method => :rms)
        #   CarrierWave::AudioWaveform::Waveformer.generate("Kickstart My Heart.wav", :color => "#ff00ff", :logger => $stdout)
        #
        def generate(source, options={})
          options = DefaultOptions.merge(options)
          filename = options[:filename] || self.generate_image_filename(source, options[:type])

          raise ArgumentError.new("No source audio filename given, must be an existing sound file.") unless source
          raise ArgumentError.new("No destination filename given for waveform") unless filename
          raise RuntimeError.new("Source audio file '#{source}' not found.") unless File.exist?(source)

          old_source = source
          source = generate_wav_source(source)

          @log = Log.new(options[:logger])
          @log.start!

          if options[:auto_width]
            RubyAudio::Sound.open(source) do |audio|
              options[:width] = (audio.info.length * 1000 / options[:auto_width].to_i).ceil
            end
          end

          # Frames gives the amplitudes for each channel, for our waveform we're
          # saying the "visual" amplitude is the average of the amplitude across all
          # the channels. This might be a little weird w/ the "peak" method if the
          # frames are very wide (i.e. the image width is very small) -- I *think*
          # the larger the frames are, the more "peaky" the waveform should get,
          # perhaps to the point of inaccurately reflecting the actual sound.
          samples = frames(source, options[:width], options[:method]).collect do |frame|
            frame.inject(0.0) { |sum, peak| sum + peak } / frame.size
          end

          @log.timed("\nDrawing...") do
            # Don't remove the file until we're sure the
            # source was readable
            if File.exists?(filename)
              @log.out("Output file #{filename} encountered. Removing.")
              File.unlink(filename)
            end

            image = draw samples, options

            if options[:type] == :svg
              File.open(filename, 'w') do |f|
                f.puts image
              end
            else
              image.save filename
            end
          end

          if source != old_source
            @log.out("Removing temporary file at #{source}")
            FileUtils.rm(source)
          end

          @log.done!("Generated waveform '#{filename}'")

          filename
        end

        def generate_image_filename(source, image_type)
          ext = File.extname(source)
          source_file_path_without_extension = File.join File.dirname(source), File.basename(source, ext)

          if image_type == :svg
            "#{source_file_path_without_extension}.svg"
          else
            "#{source_file_path_without_extension}.png"
          end
        end

        private


        # Returns a wav file if one was not passed in, or the original if it was
        def generate_wav_source(source)
          ext = File.extname(source)
          ext_gsubbed = ext.gsub(/\./, '')

          if ext != ".wav"
            input_options = { type: ext_gsubbed }
            output_options = { type: "wav" }
            source_filename_without_extension = File.basename(source, ext)
            output_file_path = File.join File.dirname(source), "tmp_#{source_filename_without_extension}_#{Time.now.to_i}.wav"
            converter = Sox::Cmd.new
            converter.add_input source, input_options
            converter.set_output output_file_path, output_options
            converter.run
            output_file_path
          else
            source
          end
        rescue Sox::Error => e
          raise e unless e.message.include?("FAIL formats:")
          raise RuntimeError.new("Source file #{source} could not be converted to .wav by Sox (Sox: #{e.message})")
        end

        # Returns a sampling of frames from the given RubyAudio::Sound using the
        # given method the sample size is determined by the given pixel width --
        # we want one sample frame per horizontal pixel.
        def frames(source, width, method = :peak)
          raise ArgumentError.new("Unknown sampling method #{method}") unless [ :peak, :rms ].include?(method)

          frames = []

          RubyAudio::Sound.open(source) do |audio|
            frames_read = 0
            frames_per_sample = (audio.info.frames.to_f / width.to_f).to_i
            sample = RubyAudio::Buffer.new("float", frames_per_sample, audio.info.channels)

            @log.timed("Sampling #{frames_per_sample} frames per sample: ") do
              while(frames_read = audio.read(sample)) > 0
                frames << send(method, sample, audio.info.channels)
                @log.out(".")
              end
            end
          end

          frames
        rescue RubyAudio::Error => e
          raise e unless e.message == "File contains data in an unknown format."
          raise RuntimeError.new("Source audio file #{source} could not be read by RubyAudio library -- Hint: non-WAV files are no longer supported, convert to WAV first using something like ffmpeg (RubyAudio: #{e.message})")
        end

        def draw(samples, options)
          if options[:type] == :svg
            draw_svg(samples, options)
          else
            draw_png(samples, options)
          end
        end

        def draw_svg(samples, options)
          image = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3/org/1999/xlink\" viewbox=\"0 0 #{options[:width]} #{options[:height]}\" preserveAspectRatio=\"none\" width=\"100%\" height=\"100%\">"          
          if options[:hide_style].nil?
            image+= "<style>"
            image+= "svg {"
            image+= "stroke: #000;"
            image+= "stroke-width: 1;"
            image+= "}"
            image+= "use.waveform-progress {"
            image+= "stroke-width: 2;"
            image+= "clip-path: polygon(0% 0%, 0% 0%, 0% 100%, 0% 100%);"
            image+= "}"
            image+= "svg path {"
            image+= "stroke: inherit;"
            image+= "stroke-width: inherit;"
            image+= "}"
            image+= "</style>"
          end
          image+= "<defs>"
          if options[:gradient]
            options[:gradient].each_with_index do |grad, id|
              image+= "<linearGradient id=\"linear#{id}\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">"
              image+= "<stop offset=\"0%\" stop-color=\"#{grad[0]}\"/>"
              image+= "<stop offset=\"100%\" stop-color=\"#{grad[1]}\"/>"
              image+= "</linearGradient>"
            end
          end
          uniqueWaveformID = "waveform-#{SecureRandom.uuid}"
          image+= "<g id=\"#{uniqueWaveformID}\">"
          image+= "<g transform=\"translate(0, #{options[:height] / 2.0})\">"
          image+= '<path stroke="currrentColor" d="'

          samples       = spaced_samples(samples, options[:sample_width], options[:gap_width]) if options[:sample_width]
          max           = samples.reject {|v| v.nil? }.max
          height_factor = (options[:height] / 2.0) / max

          samples.each_with_index do |sample, pos|
            next if sample.nil?

            amplitude = sample * height_factor
            top       = (0 - amplitude).round
            bottom    = (0 + amplitude).round

            image+= " M#{pos},#{top} V#{bottom}"
          end

          image+= '"/>'
          image+= "</g>"
          image+= "</g>"
          image+= "</defs>"
          image+= "<use class=\"waveform-base\" href=\"##{uniqueWaveformID}\" />"
          image+= "<use class=\"waveform-progress\" href=\"##{uniqueWaveformID}\" />"
          image+= "</svg>"
        end

        # Draws the given samples using the given options, returns a ChunkyPNG::Image.
        def draw_png(samples, options)
          image = ChunkyPNG::Image.new(options[:width], options[:height],
            options[:background_color] == :transparent ? ChunkyPNG::Color::TRANSPARENT : options[:background_color]
          )

          if options[:color] == :transparent
            color = transparent = ChunkyPNG::Color.from_hex(
              # Have to do this little bit because it's possible the color we were
              # intending to use a transparency mask *is* the background color, and
              # then we'd end up wiping out the whole image.
              options[:background_color].downcase == TransparencyMask ? TransparencyAlternate : TransparencyMask
            )
          else
            color = ChunkyPNG::Color.from_hex(options[:color])
          end

          # Calling "zero" the middle of the waveform, like there's positive and
          # negative amplitude
          zero = options[:height] / 2.0

          # If a sample_width is passed, let's space those things out
          if options[:sample_width]
            samples = spaced_samples(samples, options[:sample_width], options[:gap_width])
          end

          samples.each_with_index do |sample, x|
            next if sample.nil?
            # Half the amplitude goes above zero, half below
            amplitude = sample * options[:height].to_f / 2.0
            # If you give ChunkyPNG floats for pixel positions all sorts of things
            # go haywire.
            image.line(x, (zero - amplitude).round, x, (zero + amplitude).round, color)
          end

          # Simple transparency masking, it just loops over every pixel and makes
          # ones which match the transparency mask color completely clear.
          if transparent
            (0..image.width - 1).each do |x|
              (0..image.height - 1).each do |y|
                image[x, y] = ChunkyPNG::Color.rgba(0, 0, 0, 0) if image[x, y] == transparent
              end
            end
          end

          image
        end

        def spaced_samples samples, sample_width = 1, gap_width = 1
          sample_width = sample_width.to_i >= 1 ? sample_width.to_i : 1
          gap_width = gap_width.to_i >= 1 ? gap_width.to_i : 1
          width_counter = sample_width
          current_sample_index = 0
          spaced_samples = []
          avg = nil
          while samples[current_sample_index]
            at_front_of_image = current_sample_index < sample_width

            # This determines if it's a gap, but we don't want 
            # a gap to start with, hence the last booelan check
            if width_counter.to_i > sample_width.to_i && !at_front_of_image
              # This is a gap
              spaced_samples << nil
              width_counter -= 1
            else
              # This is a sample
              # If this is a new block of samples, get the average
              if avg.nil?
                avg = calculate_avg_sample(samples, current_sample_index, sample_width)
              end
              spaced_samples << avg
              # This is 1-indexed since it starts at sample_width 
              # (or sample_width + gap_width for anything other than the initial passes)
              if width_counter.to_i < 2
                width_counter = sample_width + gap_width
                avg = nil
              else
                width_counter -= 1
              end
            end
            current_sample_index += 1
          end

          spaced_samples
        end

        # Calculate the average of a group of samples
        # Return the sample's value if it's a group of 1
        def calculate_avg_sample(samples, current_sample_index, sample_width)
          if sample_width > 1
            floats = samples[current_sample_index..(current_sample_index + sample_width - 1)].collect(&:to_f)
            #floats.inject(:+) / sample_width
            channel_rms(floats)
          else
            samples[current_sample_index]
          end
        end

        # Returns an array of the peak of each channel for the given collection of
        # frames -- the peak is individual to the channel, and the returned collection
        # of peaks are not (necessarily) from the same frame(s).
        def peak(frames, channels=1)
          peak_frame = []
          (0..channels-1).each do |channel|
            peak_frame << channel_peak(frames, channel)
          end
          peak_frame
        end

        # Returns an array of rms values for the given frameset where each rms value is
        # the rms value for that channel.
        def rms(frames, channels=1)
          rms_frame = []
          (0..channels-1).each do |channel|
            rms_frame << channel_rms(frames, channel)
          end
          rms_frame
        end

        # Returns the peak voltage reached on the given channel in the given collection
        # of frames.
        #
        # TODO: Could lose some resolution and only sample every other frame, would
        # likely still generate the same waveform as the waveform is so comparitively
        # low resolution to the original input (in most cases), and would increase
        # the analyzation speed (maybe).
        def channel_peak(frames, channel=0)
          peak = 0.0
          frames.each do |frame|
            next if frame.nil?
            frame = Array(frame)
            peak = frame[channel].abs if frame[channel].abs > peak
          end
          peak
        end

        # Returns the rms value across the given collection of frames for the given
        # channel.
        def channel_rms(frames, channel=0)
          Math.sqrt(frames.inject(0.0){ |sum, frame| sum += (frame ? Array(frame)[channel] ** 2 : 0) } / frames.size)
        end
      end
    end

    class Waveformer
      # A simple class for logging + benchmarking, nice to have good feedback on a
      # long batch operation.
      #
      # There's probably 10,000,000 other bechmarking classes, but writing this was
      # easier than using Google.
      class Log
        attr_accessor :io

        def initialize(io=$stdout)
          @io = io
        end

        # Prints the given message to the log
        def out(msg)
          io.print(msg) if io
        end

        # Prints the given message to the log followed by the most recent benchmark
        # (note that it calls .end! which will stop the benchmark)
        def done!(msg="")
          out "#{msg} (#{self.end!}s)\n"
        end

        # Starts a new benchmark clock and returns the index of the new clock.
        #
        # If .start! is called again before .end! then the time returned will be
        # the elapsed time from the next call to start!, and calling .end! again
        # will return the time from *this* call to start! (that is, the clocks are
        # LIFO)
        def start!
          (@benchmarks ||= []) << Time.now
          @current = @benchmarks.size - 1
        end

        # Returns the elapsed time from the most recently started benchmark clock
        # and ends the benchmark, so that a subsequent call to .end! will return
        # the elapsed time from the previously started benchmark clock.
        def end!
          elapsed = (Time.now - @benchmarks[@current])
          @current -= 1
          elapsed
        end

        # Returns the elapsed time from the benchmark clock w/ the given index (as
        # returned from when .start! was called).
        def time?(index)
          Time.now - @benchmarks[index]
        end

        # Benchmarks the given block, printing out the given message first (if
        # given).
        def timed(message=nil, &block)
          start!
          out(message) if message
          yield
          done!
        end
      end
    end
  end
end