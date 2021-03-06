module MCollective
  module DDL
    # The base class for all kinds of DDL files.  DDL files when
    # run gets parsed and builds up a hash of the basic primitive
    # types, ideally restricted so it can be converted to JSON though
    # today there are some Ruby Symbols in them which might be fixed
    # laster on.
    #
    # The Hash being built should be stored in @entities, the format
    # is generally not prescribed but there's a definite feel to how
    # DDL files look so study the agent and discovery ones to see how
    # the structure applies to very different use cases.
    #
    # For every plugin type you should have a single word name - that
    # corresponds to the directory in the libdir where these plugins
    # live.  If you need anything above and beyond 'metadata' in your
    # plugin DDL then add a PlugintypeDDL class here and add your
    # specific behaviors to those.
    class Base
      include Translatable

      attr_reader :meta, :entities, :pluginname, :plugintype, :usage, :requirements

      def initialize(plugin, plugintype=:agent, loadddl=true)
        @entities = {}
        @meta = {}
        @usage = ""
        @config = Config.instance
        @pluginname = plugin
        @plugintype = plugintype.to_sym
        @requirements = {}

        loadddlfile if loadddl
      end

      # Generates help using the template based on the data
      # created with metadata and input.
      #
      # If no template name is provided one will be chosen based
      # on the plugin type.  If the provided template path is
      # not absolute then the template will be loaded relative to
      # helptemplatedir configuration parameter
      def help(template=nil)
        template = template_for_plugintype unless template
        template = File.join(@config.helptemplatedir, template) unless template.start_with?(File::SEPARATOR)

        template = File.read(template)
        meta = @meta
        entities = @entities

        unless template == "metadata-help.erb"
          metadata_template = File.join(@config.helptemplatedir, "metadata-help.erb")
          metadata_template = File.read(metadata_template)
          metastring = ERB.new(metadata_template, 0, '%')
          metastring = metastring.result(binding)
        end

        erb = ERB.new(template, 0, '%')
        erb.result(binding)
      end

      def usage(usage_text)
        @usage = usage_text
      end

      def template_for_plugintype
        case @plugintype
        when :agent
          return "rpc-help.erb"
        else
          if File.exists?(File.join(@config.helptemplatedir,"#{@plugintype}-help.erb"))
            return "#{@plugintype}-help.erb"
          else
            # Default help template gets loaded if plugintype-help does not exist.
            return "metadata-help.erb"
          end
        end
      end

      def loadddlfile
        if ddlfile = findddlfile
          instance_eval(File.read(ddlfile), ddlfile, 1)
        else
          raise_code(:PLMC18, "Can't find DDL for %{type} plugin '%{name}'", :debug, :type => @plugintype, :name => @pluginname)
        end
      end

      def findddlfile(ddlname=nil, ddltype=nil)
        ddlname = @pluginname unless ddlname
        ddltype = @plugintype unless ddltype

        @config.libdir.each do |libdir|
          ddlfile = File.join([libdir, "mcollective", ddltype.to_s, "#{ddlname}.ddl"])
          if File.exist?(ddlfile)
            log_code(:PLMC18, "Found %{ddlname} ddl at %{ddlfile}", :debug, :ddlname => ddlname, :ddlfile => ddlfile)
            return ddlfile
          end
        end
        return false
      end

      def validate_requirements
        if requirement = @requirements[:mcollective]
          if Util.mcollective_version == "@DEVELOPMENT_VERSION@"
            log_code(:PLMC19, "DDL requirements validation being skipped in development", :warn)
            return true
          end

          if Util.versioncmp(Util.mcollective_version, requirement) < 0
            DDL.validation_fail!(:PLMC20, "%{type} plugin '%{name}' requires MCollective version %{requirement} or newer", :debug, :type => @plugintype.to_s.capitalize, :name => @pluginname, :requirement => requirement)
          end
        end

        true
      end

      # validate strings, lists and booleans, we'll add more types of validators when
      # all the use cases are clear
      #
      # only does validation for arguments actually given, since some might
      # be optional.  We validate the presense of the argument earlier so
      # this is a safe assumption, just to skip them.
      #
      # :string can have maxlength and regex.  A maxlength of 0 will bypasss checks
      # :list has a array of valid values
      def validate_input_argument(input, key, argument)
        Validator.load_validators

        case input[key][:type]
        when :string
          Validator.validate(argument, :string)

          Validator.length(argument, input[key][:maxlength].to_i)

          Validator.validate(argument, input[key][:validation])

        when :list
          Validator.validate(argument, input[key][:list])

        else
          Validator.validate(argument, input[key][:type])
        end

        return true
      rescue => e
        DDL.validation_fail!(:PLMC21, "Cannot validate input '%{input}': %{error}", :debug, :input => key, :error => e.to_s)
      end

      # Registers an input argument for a given action
      #
      # See the documentation for action for how to use this
      def input(argument, properties)
        raise_code(:PLMC22, "Cannot determine what entity input '%{entity}' belongs to", :error, :entity => @current_entity) unless @current_entity

        entity = @current_entity

        [:prompt, :description, :type].each do |arg|
          raise_code(:PLMC23, "Input needs a :%{property} property", :debug, :property => arg) unless properties.include?(arg)
        end

        @entities[entity][:input][argument] = {:prompt => properties[:prompt],
                                               :description => properties[:description],
                                               :type => properties[:type],
                                               :default => properties[:default],
                                               :optional => properties[:optional]}

        case properties[:type]
          when :string
            raise "Input type :string needs a :validation argument" unless properties.include?(:validation)
            raise "Input type :string needs a :maxlength argument" unless properties.include?(:maxlength)

            @entities[entity][:input][argument][:validation] = properties[:validation]
            @entities[entity][:input][argument][:maxlength] = properties[:maxlength]

          when :list
            raise "Input type :list needs a :list argument" unless properties.include?(:list)

            @entities[entity][:input][argument][:list] = properties[:list]
        end
      end

      # Registers an output argument for a given action
      #
      # See the documentation for action for how to use this
      def output(argument, properties)
        raise "Cannot figure out what action input #{argument} belongs to" unless @current_entity
        raise "Output #{argument} needs a description argument" unless properties.include?(:description)
        raise "Output #{argument} needs a display_as argument" unless properties.include?(:display_as)

        action = @current_entity

        @entities[action][:output][argument] = {:description => properties[:description],
                                                :display_as  => properties[:display_as],
                                                :default     => properties[:default]}
      end

      def requires(requirement)
        raise "Requirement should be a hash in the form :item => 'requirement'" unless requirement.is_a?(Hash)

        valid_requirements = [:mcollective]

        requirement.keys.each do |key|
          unless valid_requirements.include?(key)
            raise "Requirement %s is not a valid requirement, only %s is supported" % [key, valid_requirements.join(", ")]
          end

          @requirements[key] = requirement[key]
        end

        validate_requirements
      end

      # Registers meta data for the introspection hash
      def metadata(meta)
        [:name, :description, :author, :license, :version, :url, :timeout].each do |arg|
          raise "Metadata needs a :#{arg} property" unless meta.include?(arg)
        end

        @meta = meta
      end
    end
  end
end
