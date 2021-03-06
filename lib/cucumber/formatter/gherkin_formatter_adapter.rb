require 'cucumber/formatter/io'
require 'gherkin/formatter/argument'

module Cucumber
  module Formatter
    # Adapts Cucumber formatter events to Gherkin formatter events
    # This class will disappear when Cucumber is based on Gherkin's model.
    class GherkinFormatterAdapter
      def initialize(gherkin_formatter, print_empty_match, options)
        @gf = gherkin_formatter
        @print_empty_match = print_empty_match
        @options = options
        @delayed_messages = []
        @delayed_embeddings = []
      end

      def before_feature(feature)
        @gf.uri(feature.file)
        @gf.feature(feature.gherkin_statement)
      end

      def before_background(background)
        @outline = false
        @before_steps = true
        @gf.background(background.gherkin_statement)
      end

      def before_feature_element(feature_element)
        @before_steps = true
        case(feature_element)
        when Core::Ast::Scenario
          @outline = false
          @gf.scenario(feature_element.gherkin_statement)
        when Core::Ast::ScenarioOutline
          @outline = true
          if @options[:expand]
            @in_instantiated_scenario = false
            @current_scenario_hash = to_hash(feature_element.gherkin_statement)
          else
            @gf.scenario_outline(feature_element.gherkin_statement)
          end
        else
          raise "Bad type: #{feature_element.class}"
        end
      end

      def scenario_name(keyword, name, file_colon_line, source_indent)
        if @outline and @options[:expand]
          return if not @in_instantiated_scenario
          if @new_example_table
            @example_row = 1
            @new_example_table = false
          else
            @example_row += 1
          end
          example_row_hash = @current_example_rows[@example_row].to_hash
          scenario = Gherkin::Formatter::Model::Scenario.new(
              @current_scenario_hash['comments'],
              @current_scenario_hash['tags'],
              @current_scenario_hash['keyword'],
              @current_scenario_hash['name'],
              @current_scenario_hash['description'],
              example_row_hash['line'],
              example_row_hash['id'])
          @gf.scenario(scenario)
        end
      end

      def before_step(step)
        unless @outline and @options[:expand]
          @gf.step(step.gherkin_statement)
          pass_delayed_output
          @before_steps = false
        else 
          if @in_instantiated_scenario
            @current_step_hash = to_hash(step.gherkin_statement)
          end
        end
        if @print_empty_match
          if(@outline)
            match = Gherkin::Formatter::Model::Match.new(step.gherkin_statement.outline_args, nil)
          else
            match = Gherkin::Formatter::Model::Match.new([], nil)
          end
          @gf.match(match)
        end
      end

      def before_step_result(keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line)
        arguments = step_match.step_arguments.map{|a| Gherkin::Formatter::Argument.new(a.offset, a.val)}
        location = step_match.file_colon_line
        match = Gherkin::Formatter::Model::Match.new(arguments, location)
        if @print_empty_match
          # Trick the formatter to believe that's what was printed previously so we get arg highlights on #result
          @gf.instance_variable_set('@match', match)
        else
          unless @outline and @options[:expand]
            @gf.match(match)
          end
        end

        error_message = exception ? "#{exception.message} (#{exception.class})\n#{exception.backtrace.join("\n")}" : nil
        unless @outline
          @gf.result(Gherkin::Formatter::Model::Result.new(status, nil, error_message))
        else
          if @options[:expand] and @in_instantiated_scenario
            @current_match = match
            @current_result = Gherkin::Formatter::Model::Result.new(status, nil, error_message)
          end
        end
      end

      def step_name(keyword, step_match, status, source_indent, background, file_colon_line)
        if @outline and @options[:expand] and @in_instantiated_scenario
          @gf.step(Gherkin::Formatter::Model::Step.new(
              @current_step_hash['comments'],
              @current_step_hash['keyword'],
              step_match.format_args(),
              file_colon_line.split(':')[1].to_i,
              @current_step_hash['rows'],
              @current_step_hash['doc_string']))
          pass_delayed_output
          @before_steps = false
          @gf.match(@current_match)
          @gf.result(@current_result)
        end
      end

      def before_examples(examples)
        unless @options[:expand]
          @gf.examples(examples.gherkin_statement)
        else
          @in_instantiated_scenario = true
          @new_example_table = true
          @current_example_rows = to_hash(examples.gherkin_statement)['rows']
        end
      end

      #used for capturing duration
      def after_step(step)
        unless @outline and @options[:expand] and not @in_instantiated_scenario
          unless step.duration == :unknown
            @gf.append_duration(step.duration / 10 ** 9.0)
          end
        end
      end

      def after_feature(feature)
        @gf.eof
      end

      def after_features(features)
        @gf.done
      end

      def embed(file, mime_type, label)
        if File.file?(file)
          data = File.open(file, 'rb') { |f| f.read }
        else
          if mime_type =~ /;base64$/
            mime_type = mime_type[0..-8]
            data = Base64.decode64(file)
          else
            data = file
          end
        end
        if defined?(JRUBY_VERSION)
          data = data.to_java_bytes
        end
        unless @before_steps
          @gf.embedding(mime_type, data)
        else
          @delayed_embeddings.push [mime_type, data]
        end
      end

      def puts(message)
        unless @before_steps
          @gf.write(message)
        else
          @delayed_messages.push message
        end
      end

      private

      def to_hash(gherkin_statement)
        if defined?(JRUBY_VERSION)
          gherkin_statement.toMap()
        else
          gherkin_statement.to_hash
        end
      end

      def pass_delayed_output
        @delayed_messages.each { |message| @gf.write(message) }
        @delayed_embeddings.each { |embed_data| @gf.embedding(embed_data[0], embed_data[1]) }
        @delayed_messages = []
        @delayed_embeddings = []
      end
    end
  end
end
