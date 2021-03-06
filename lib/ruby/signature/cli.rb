require "optparse"

module Ruby
  module Signature
    class CLI
      class LibraryOptions
        attr_reader :libs
        attr_reader :dirs
        attr_accessor :no_stdlib

        def initialize()
          @libs = []
          @dirs = []
          @no_stdlib = false
        end

        def setup(loader)
          libs.each do |lib|
            loader.add(library: lib)
          end

          dirs.each do |dir|
            loader.add(path: Pathname(dir))
          end

          loader.stdlib_root = nil if no_stdlib

          loader
        end
      end

      attr_reader :stdout
      attr_reader :stderr

      def initialize(stdout:, stderr:)
        @stdout = stdout
        @stderr = stderr
      end

      COMMANDS = [:ast, :list, :ancestors, :methods, :method, :version]

      def library_parse(opts, options:)
        opts.on("-r LIBRARY") do |lib|
          options.libs << lib
        end

        opts.on("-I DIR") do |dir|
          options.dirs << dir
        end

        opts.on("--no-stdlib") do
          options.no_stdlib = true
        end

        opts
      end

      def run(args)
        options = LibraryOptions.new

        OptionParser.new do |opts|
          library_parse(opts, options: options)
        end.order!(args)

        command = args.shift&.to_sym

        if COMMANDS.include?(command)
          __send__ :"run_#{command}", args, options
        else
          run_help()
        end
      end

      def run_help
        stdout.puts "Available commands: #{COMMANDS.join(", ")}"
      end

      def run_ast(args, options)
        env = Environment.new()
        loader = EnvironmentLoader.new(env: env)

        options.setup(loader)

        loader.load

        stdout.print JSON.generate(env.declarations)
        stdout.flush
      end

      def run_list(args, options)
        list = []

        OptionParser.new do |opts|
          opts.on("--class") { list << :class }
          opts.on("--module") { list << :module }
          opts.on("--interface") { list << :interface }
        end.order!(args)

        list.push(:class, :module, :interface) if list.empty?

        env = Environment.new()
        loader = EnvironmentLoader.new(env: env)

        options.setup(loader)

        loader.load

        env.each_decl.sort_by(&:to_s).each do |type_name|
          decl = env.find_class(type_name)

          case decl
          when AST::Declarations::Class
            if list.include?(:class)
              stdout.puts "#{type_name} (class)"
            end
          when AST::Declarations::Module
            if list.include?(:module)
              stdout.puts "#{type_name} (module)"
            end
          when AST::Declarations::Interface
            if list.include?(:interface)
              stdout.puts "#{type_name} (interface)"
            end
          end
        end
      end

      def run_ancestors(args, options)
        kind = :instance

        OptionParser.new do |opts|
          opts.on("--instance") { kind = :instance }
          opts.on("--singleton") { kind = :singleton }
        end.order!(args)

        env = Environment.new()
        loader = EnvironmentLoader.new(env: env)

        options.setup(loader)

        loader.load

        builder = DefinitionBuilder.new(env: env)
        type_name = parse_type_name(args[0]).absolute!

        if env.class?(type_name)
          ancestor = case kind
                     when :instance
                       definition = env.find_class(type_name)
                       Definition::Ancestor::Instance.new(name: type_name,
                                                          args: Types::Variable.build(definition.type_params))
                     when :singleton
                       Definition::Ancestor::Singleton.new(name: type_name)
                     end

          ancestors = builder.build_ancestors(ancestor)

          ancestors.each do |ancestor|
            case ancestor
            when Definition::Ancestor::Singleton
              stdout.puts "singleton(#{ancestor.name})"
            when Definition::Ancestor::ExtensionSingleton
              stdout.puts "singleton(#{ancestor.name} (#{ancestor.extension_name}))"
            when Definition::Ancestor::Instance
              if ancestor.args.empty?
                stdout.puts ancestor.name.to_s
              else
                stdout.puts "#{ancestor.name}[#{ancestor.args.join(", ")}]"
              end
            when Definition::Ancestor::ExtensionInstance
              if ancestor.args.empty?
                stdout.puts "#{ancestor.name} (#{ancestor.extension_name})"
              else
                stdout.puts "#{ancestor.name}[#{ancestor.args.join(", ")}] (#{ancestor.extension_name})"
              end
            end
          end
        else
          stdout.puts "Cannot find class: #{type_name}"
        end
      end

      def run_methods(args, options)
        kind = :instance
        inherit = true

        OptionParser.new do |opts|
          opts.on("--instance") { kind = :instance }
          opts.on("--singleton") { kind = :singleton }
          opts.on("--inherit") { inherit = true }
          opts.on("--no-inherit") { inherit = false }
        end.order!(args)

        env = Environment.new()
        loader = EnvironmentLoader.new(env: env)

        options.setup(loader)

        loader.load

        builder = DefinitionBuilder.new(env: env)
        type_name = parse_type_name(args[0]).absolute!

        if env.class?(type_name)
          definition = case kind
                       when :instance
                         builder.build_instance(type_name)
                       when :singleton
                         builder.build_singleton(type_name)
                       end

          definition.methods.keys.sort.each do |name|
            method = definition.methods[name]
            if inherit || method.implemented_in == definition.declaration
              stdout.puts "#{name} (#{method.accessibility})"
            end
          end
        else
          stdout.puts "Cannot find class: #{type_name}"
        end
      end

      def run_method(args, options)
        kind = :instance

        OptionParser.new do |opts|
          opts.on("--instance") { kind = :instance }
          opts.on("--singleton") { kind = :singleton }
        end.order!(args)

        unless args.size == 2
          stdout.puts "Expected two arguments, but given #{args.size}."
          return
        end

        env = Environment.new()
        loader = EnvironmentLoader.new(env: env)

        options.setup(loader)

        loader.load

        builder = DefinitionBuilder.new(env: env)
        type_name = parse_type_name(args[0]).absolute!
        method_name = args[1].to_sym

        unless env.class?(type_name)
          stdout.puts "Cannot find class: #{type_name}"
          return
        end

        definition = case kind
                     when :instance
                       builder.build_instance(type_name)
                     when :singleton
                       builder.build_singleton(type_name)
                     end

        method = definition.methods[method_name]

        unless method
          stdout.puts "Cannot find method: #{method_name}"
          return
        end

        stdout.puts "#{type_name}#{kind == :instance ? "#" : "."}#{method_name}"
        stdout.puts "  defined_in: #{method.defined_in&.name&.absolute!}"
        stdout.puts "  implementation: #{method.implemented_in.name.absolute!}"
        stdout.puts "  accessibility: #{method.accessibility}"
        stdout.puts "  types:"
        separator = " "
        for type in method.method_types
          stdout.puts "    #{separator} #{type}"
          separator = "|"
        end
      end

      def run_version(args, options)
        stdout.puts "ruby-signature #{VERSION}"
      end

      def parse_type_name(string)
        Namespace.parse(string).yield_self do |namespace|
          last = namespace.path.last
          TypeName.new(name: last, namespace: namespace.parent)
        end
      end
    end
  end
end
