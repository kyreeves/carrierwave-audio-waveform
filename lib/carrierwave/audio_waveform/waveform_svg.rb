require 'ruby-audio'
require 'ruby-sox'
require 'fileutils'

module CarrierWave
  module AudioWaveform
    class WaveformSvg
      DEFAULT_OPTIONS = {
        :method => :peak,
        :samples => 100,
        :amplitude => 1,
        :gap_width => 3,
        :bar_width => 1,
        :height => 100,
      }
    
      # Scope these under Waveform so you can catch the ones generated by just this
      # class.
      class RuntimeError < ::RuntimeError;end;
      class ArgumentError < ::ArgumentError;end;
    
      class << self
        # Generate a Waveform SVG file from the given filename with the given options.
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
        #   :samples => The amount of samples wanted. The may have ±10% of the
        #     samples requested.
        #
        #     Default is 100.
        #
        #   :amplitude => The amplitude of the final values
        #     Default is 1.
        #
        #   :gap_width => The width between the waveform bars
        #     Default is 3.
        #
        #   :bar_width => The width of the waveform bars
        #     Default is 3.
        #
        #   :height => The viewBox height
        #     Default is 100.
        #
        # Example:
        #   WaveformSvg.generate("Kickstart My Heart.wav")
        #   WaveformSvg.generate("Kickstart My Heart.wav", samples: 50)
        #
        def generate(source, options={})
          options = DEFAULT_OPTIONS.merge(options)
          filename = options[:filename] || self.generate_svg_filename(source)
          raise ArgumentError.new("No source audio filename given, must be an existing sound file.") unless source
          raise ArgumentError.new("No destination filename given for waveform") unless filename
          raise RuntimeError.new("Source audio file '#{source}' not found.") unless File.exist?(source)

          old_source = source
          source = generate_wav_source(source)
    
          # Frames gives the amplitudes for each channel, for our waveform we're
          # saying the "visual" amplitude is the average of the amplitude across all
          # the channels. This might be a little weird w/ the "peak" method if the
          # frames are very wide (i.e. the image width is very small) -- I *think*
          # the larger the frames are, the more "peaky" the waveform should get,
          # perhaps to the point of inaccurately reflecting the actual sound.
          samples = frames(source, options[:samples], options[:method]).collect do |frame|
            frame.inject(0.0) { |sum, peak| sum + peak } / frame.size
          end

          samples = normalize(samples, options)

          # Don't remove the file until we're sure the
          # source was readable
          if File.exists?(filename)
            File.unlink(filename)
          end

          svg = draw_svg(samples, options)

          File.open(filename, 'w') do |f|
            f.puts svg
          end

          if source != old_source
            FileUtils.rm(source)
          end

          filename
        end

        def generate_svg_filename(source)
          ext = File.extname(source)
          source_file_path_without_extension = File.join File.dirname(source), File.basename(source, ext)
          "#{source_file_path_without_extension}.svg"
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
        # given method
        def frames(source, samples, method = :peak)
          raise ArgumentError.new("Unknown sampling method #{method}") unless [ :peak, :rms ].include?(method)
    
          frames = []
    
          RubyAudio::Sound.open(source) do |audio|
            frames_read = 0
            frames_per_sample = (audio.info.frames.to_f / samples.to_f).to_i
            sample = RubyAudio::Buffer.new("float", frames_per_sample, audio.info.channels)
    
            while(frames_read = audio.read(sample)) > 0
              frames << send(method, sample, audio.info.channels)
            end
          end
    
          frames
        rescue RubyAudio::Error => e
          raise e unless e.message == "File contains data in an unknown format."
          raise JsonWaveform::RuntimeError.new("Source audio file #{source} could not be read by RubyAudio library -- Hint: non-WAV files are no longer supported, convert to WAV first using something like ffmpeg (RubyAudio: #{e.message})")
        end
    
        def normalize(samples, options)
          samples.map do |sample|
            # Half the amplitude goes above zero, half below
            amplitude = sample * options[:amplitude].to_f
            rounded = amplitude.round(2)
            rounded.zero? || rounded == 1 ? rounded.to_i : rounded
          end
        end

        def draw_svg(samples, options)
          viewbox_width = samples.size * options[:gap_width]
          viewbox_height = options[:height]

          image = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3/org/1999/xlink\" viewBox=\"0 0 #{viewbox_width} #{viewbox_height}\" preserveAspectRatio=\"none\" width=\"100%\" height=\"100%\" fill=\"currentColor\">"
          if (options[:hide_style].nil? || options[:hide_style] == false)
            image+= "<style>"
            image+= "svg {"
            image+= "color: #c4c8ce;"
            image+= "}"
            image+= "use.waveform-base {"
            image+= "color: #c4c8ce;"
            image+= "}"
            image+= "use.waveform-progress {"
            image+= "color: #9d34a5;"
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
          samples.each_with_index do |sample, pos|
            next if sample.nil?

            width = options[:bar_width]
            height = (sample * viewbox_height).round
            x = pos * options[:gap_width]
            y = (viewbox_height - height) / 2.0

            image+= "<rect x=\"#{x}\" y=\"#{y}\" width=\"#{width}\" height=\"#{height}\" fill=\"currentColor\"/>"
          end
          image+= "</g>"
          image+= "</defs>"
          image+= "<use class=\"waveform-base\" href=\"##{uniqueWaveformID}\" />"
          image+= "<use class=\"waveform-progress\" href=\"##{uniqueWaveformID}\" />"
          image+= "</svg>"

          image
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
  end
end
