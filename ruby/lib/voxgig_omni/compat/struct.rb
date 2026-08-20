# Drop-in replacement for the in-situ test runner in the voxgig/struct
# repository (`ruby/voxgig_runner.rb`).
#
# struct's own runner and omni's runner implement the same spec format;
# this module exposes omni behind struct's exact runner API, so a struct
# port switches over by changing one require:
#
#   -require_relative 'voxgig_runner'
#   +require_relative 'omni'
#
# where `omni` is a small local-checkout resolver in the port's directory
# that mixes this module into `VoxgigRunner`. Everything else - the
# corpus, the SDK, the test file - is unchanged. This is the Ruby peer of
# javascript/compat/struct.js and python/voxgig_omni/compat/struct.py.

require_relative '../../voxgig_omni'

module VoxgigOmni
  module Compat
    # struct's runner API, backed by omni.
    #
    # Mix into struct's own runner namespace with:
    #
    #   module VoxgigRunner
    #     include VoxgigOmni::Compat::Struct   # NULLMARK, UNDEFMARK, ...
    #     extend  VoxgigOmni::Compat::Struct   # make_runner, null_modifier
    #   end
    module Struct
      NULLMARK = VoxgigOmni::NULLMARK
      UNDEFMARK = VoxgigOmni::UNDEFMARK
      EXISTSMARK = VoxgigOmni::EXISTSMARK

      # Root of the omni Ruby port, used to skip omni's own stack frames
      # when resolving a caller-relative spec path.
      OMNIDIR = File.expand_path(File.join(__dir__, '..', '..'))

      # An omni provider that struct's test code can also treat as a
      # client. omni reads a provider as a mapping (`provider[:subject]`),
      # while struct's test files reach through the returned client as an
      # object (`client.utility.struct`). A Hash subclass with those few
      # methods satisfies both, so neither side has to change.
      class Provider < ::Hash
        def utility
          self[:sdk].utility
        end

        # struct's Ruby client builds a test instance with `test(options)`;
        # other ports call it `tester`.
        def test(options = {})
          self[:client].call(options)
        end
        alias tester test

        def sdk
          self[:sdk]
        end
      end

      # Read `name` off a container the way struct's runner does, but
      # without calling the subject. A zero-arity method is an accessor
      # (`utility.struct`) and yields its value; a method that takes
      # arguments IS the subject, so bind it rather than invoke it.
      def lookup(container, name)
        return nil if container.nil?
        return container[name] if container.is_a?(::Hash) && !container.respond_to?(name)
        return nil unless container.respond_to?(name)

        found = container.method(name)
        found.arity.zero? ? container.send(name) : found
      rescue ::NameError
        nil
      end

      # struct's Ruby port has no `undefined`, so it models absence with its
      # own `VoxgigStruct::UNDEF` singleton, while omni models it with
      # `VoxgigOmni::ABSENT`. struct's in-situ runner treated UNDEF exactly
      # as it treated nil; translating the sentinel here keeps that, and
      # keeps the two absence models from meeting.
      def structundef(sdk)
        utility = sdk.utility
        structutils = utility.respond_to?(:struct) ? utility.struct : nil
        return nil unless structutils.is_a?(::Module)
        return structutils.const_get(:UNDEF) if structutils.const_defined?(:UNDEF)

        nil
      rescue StandardError
        nil
      end

      # Replace struct's absence sentinel with omni's, at any depth.
      def absentify(val, sentinel)
        return val if sentinel.nil?
        return VoxgigOmni::ABSENT if val.equal?(sentinel)
        return val.map { |entry| absentify(entry, sentinel) } if val.is_a?(::Array)

        if val.is_a?(::Hash)
          out = {}
          val.each { |key, subval| out[key] = absentify(subval, sentinel) }
          return out
        end

        val
      end

      # A subject whose result speaks omni's absence model.
      def wrapsubject(subject, sentinel)
        return subject if sentinel.nil? || subject.nil? || !subject.respond_to?(:call)

        ->(*args) { absentify(subject.call(*args), sentinel) }
      end

      # struct passes a spec path relative to the file that loads the
      # runner, so resolve it the same way: the first stack frame outside
      # the omni package is the caller.
      def callerdir
        caller_locations.each do |loc|
          path = loc.absolute_path || loc.path
          next if path.nil?

          full = File.expand_path(path)
          return File.dirname(full) unless full.start_with?(OMNIDIR + File::SEPARATOR)
        end

        Dir.pwd
      end

      # Wrap a struct SDK client as an omni provider.
      def structprovider(sdk)
        provider = Provider.new

        # struct resolves a subject from the utility, or from utility.struct.
        provider[:subject] = lambda do |name|
          utility = sdk.utility
          found = lookup(utility, name)

          if found.nil?
            structutils = lookup(utility, :struct)
            found = lookup(structutils, name) unless structutils.nil?
          end

          wrapsubject(found, structundef(sdk))
        end

        # A DEF.client entry becomes another SDK instance.
        provider[:client] = lambda do |options|
          maker = sdk.respond_to?(:test) ? :test : :tester
          structprovider(sdk.send(maker, options))
        end

        # struct's SDK supplies its own context wrapper; the runner store
        # is reached through `utility` on the context.
        provider[:contextify] = lambda do |val|
          utility = sdk.utility
          ctx = utility.respond_to?(:contextify) ? utility.contextify(val) : val

          # struct's runner hands the utility to the context; a context is
          # a map in some SDKs and a plain object in others.
          if ctx.is_a?(::Hash)
            ctx['utility'] = utility
          elsif ctx.respond_to?(:utility=)
            ctx.utility = utility
          end

          ctx
        end

        # Client options may reference the runner store.
        provider[:inject] = lambda do |options, store|
          structutils = sdk.utility.respond_to?(:struct) ? sdk.utility.struct : nil
          return options if structutils.nil? || !structutils.respond_to?(:inject)

          structutils.inject(options, store)
        end

        provider[:sdk] = sdk
        provider
      end

      # struct's Ruby tests write flags with string keys (`{ 'null' =>
      # false }`); omni's Ruby runner reads them as symbols, which is the
      # idiomatic Ruby split between data and options. Translate.
      def normflags(flags)
        return {} if flags.nil?
        return flags unless flags.is_a?(::Hash)

        out = {}
        flags.each { |key, val| out[key.is_a?(::String) ? key.to_sym : key] = val }
        out
      end

      # Reproduce struct's ruby runner for the no-argument entries.
      #
      # struct's corpus has seventeen entries carrying no `in`, `args` or
      # `ctx`. They mean "call the subject with no arguments": each sits
      # beside an `in: null` sibling, and in `minor/typify` that sibling
      # expects a different result - canonical JavaScript agrees, typify()
      # is 1073741824 where typify(null) is 4194432.
      #
      # struct's own runners never agreed on how to spell that. ruby's
      # resolve_args passed `VoxgigStruct::UNDEF`, its own absence
      # sentinel; python left `args` empty; typescript, php and go passed
      # one absent value. omni's generic rule is the typescript one
      # (DOCS 2.2: `args = [clone(entry.in)]`).
      #
      # A compat shim exists to keep a port's behaviour identical across
      # the swap, so this restores ruby's reading by rewriting those
      # entries to an explicit `args` of one sentinel - in memory, for
      # this port only. The corpus on disk is untouched.
      #
      # The sentinel is the one already resolved off the SDK by
      # `structundef`, so the shim still never imports struct. When the
      # port has no such constant the spec is returned unchanged and the
      # generic rule applies.
      #
      # The discrimination is made HERE, on the entry, rather than on the
      # argument value: once the argument list is built an authored
      # `in: null` is indistinguishable from an absent `in`.
      #
      # This is a compat measure, not the model. The general fix is the
      # absence model: spell the state as `in: '__UNDEF__'` and let each
      # port map it to its own no-value. That needs the marker honoured in
      # input position first, so it rides a spec version bump.
      ARGKEYS = %w[in args ctx].freeze

      def undefargs(testspec, sentinel)
        return testspec if sentinel.nil?
        return testspec unless testspec.is_a?(::Hash)

        set = testspec['set']
        return testspec unless set.is_a?(::Array)
        return testspec unless set.any? { |entry| noargs?(entry) }

        patched = set.map do |entry|
          if noargs?(entry)
            entry = entry.dup
            entry['args'] = [sentinel]
          end
          entry
        end

        out = testspec.dup
        out['set'] = patched
        out
      end

      def noargs?(entry)
        entry.is_a?(::Hash) && (entry.keys & ARGKEYS).empty?
      end

      # struct's make_runner(testfile, client) signature, backed by omni.
      def make_runner(testfile, client)
        specpath =
          if testfile.is_a?(::String) && !File.absolute_path?(testfile)
            File.join(callerdir, testfile)
          else
            testfile
          end

        provider = structprovider(client)
        sentinel = structundef(client)
        runner = VoxgigOmni.make_runner(specpath, provider)

        lambda do |name = nil, store = nil|
          runpack = runner.call(name, store.nil? ? {} : store)

          omniflags = runpack[:runsetflags]
          runsetflags = lambda do |testspec, flags = nil, testsubject = nil|
            omniflags.call(undefargs(testspec, sentinel), normflags(flags),
                           wrapsubject(testsubject, sentinel))
          end
          runset = ->(testspec, testsubject = nil) { runsetflags.call(testspec, {}, testsubject) }

          {
            spec: runpack[:spec],
            runset: runset,
            runsetflags: runsetflags,
            subject: runpack[:subject],
            client: provider
          }
        end
      end

      # Convert NULLMARK sentinels back into real nulls.
      def null_modifier(val, key, parent, *rest)
        VoxgigOmni::Runner.nullmodifier(val, key, parent, *rest)
      end
      alias nullModifier null_modifier

      extend self
    end
  end
end
