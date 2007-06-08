# The container class for implementations.
class Puppet::Provider
    include Puppet::Util
    include Puppet::Util::Errors
    include Puppet::Util::Warnings
    extend Puppet::Util::Warnings

    Puppet::Util.logmethods(self, true)

    class << self
        # Include the util module so we have access to things like 'binary'
        include Puppet::Util, Puppet::Util::Docs
        include Puppet::Util::Logging
        attr_accessor :name

        # The source parameter exists so that providers using the same
        # source can specify this, so reading doesn't attempt to read the
        # same package multiple times.
        attr_accessor :source

        # LAK 2007-05-09: Keep the model stuff around for backward compatibility
        attr_reader :model
        attr_accessor :resource_type
        attr_writer :doc
    end

    # LAK 2007-05-09: Keep the model stuff around for backward compatibility
    attr_reader :model
    attr_accessor :resource
    
    def self.command(name)
        name = symbolize(name)

        if defined?(@commands) and command = @commands[name]
            # nothing
        elsif superclass.respond_to? :command and command = superclass.command(name)
            # nothing
        else
            raise Puppet::DevError, "No command %s defined for provider %s" %
                [name, self.name]
        end

        if command == :missing
            return nil
        end

        command
    end

    # Define commands that are not optional.
    def self.commands(hash)
        optional_commands(hash) do |name, path|
            confine :exists => path
        end
    end

    def self.confine(hash)
        hash.each do |p,v|
            if v.is_a? Array
                @confines[p] += v
            else
                @confines[p] << v
            end
        end
    end

    # Does this implementation match all of the default requirements?  If
    # defaults are empty, we return false.
    def self.default?
        return false if @defaults.empty?
        if @defaults.find do |fact, values|
                values = [values] unless values.is_a? Array
                if fval = Facter.value(fact).to_s and fval != ""
                    fval = fval.to_s.downcase.intern
                else
                    return false
                end

                # If any of the values match, we're a default.
                if values.find do |value| fval == value.to_s.downcase.intern end
                    false
                else
                    true
                end
            end
            return false
        else
            return true
        end
    end

    # Store how to determine defaults.
    def self.defaultfor(hash)
        hash.each do |d,v|
            @defaults[d] = v
        end
    end

    def self.defaultnum
        @defaults.length
    end

    def self.initvars
        @defaults = {}
        @commands = {}
        @origcommands = {}
        @confines = Hash.new do |hash, key|
            hash[key] = []
        end
    end

    # The method for returning a list of provider instances.  Note that it returns providers, preferably with values already
    # filled in, not resources.
    def self.instances
        raise Puppet::DevError, "Provider %s has not defined the 'instances' class method" % self.name
    end

    # Create the methods for a given command.
    def self.make_command_methods(name)
        # Now define a method for that command
        unless metaclass.method_defined? name
            meta_def(name) do |*args|
                unless command(name)
                    raise Puppet::Error, "Command %s is missing" % name
                end
                if args.empty?
                    cmd = [command(name)]
                else
                    cmd = [command(name)] + args
                end
                # This might throw an ExecutionFailure, but the system above
                # will catch it, if so.
                return execute(cmd)
            end
            
            # And then define an instance method that just calls the class method.
            # We need both, so both instances and classes can easily run the commands.
            unless method_defined? name
                define_method(name) do |*args|
                    self.class.send(name, *args)
                end
            end
        end
    end

    # Create getter/setter methods for each property our resource type supports.
    # They all get stored in @property_hash.  This method is useful
    # for those providers that use prefetch and flush.
    def self.mkmodelmethods
        warnonce "Provider.mkmodelmethods is deprecated; use Provider.mk_resource_methods"
        mk_resource_methods
    end

    # Create getter/setter methods for each property our resource type supports.
    # They all get stored in @property_hash.  This method is useful
    # for those providers that use prefetch and flush.
    def self.mk_resource_methods
        [resource_type.validproperties, resource_type.parameters].flatten.each do |attr|
            attr = symbolize(attr)
            define_method(attr) do
                @property_hash[attr] || :absent
            end

            define_method(attr.to_s + "=") do |val|
                @property_hash[attr] = val
            end
        end
    end

    self.initvars

    # Define one or more binaries we'll be using.  If a block is passed, yield the name
    # and path to the block (really only used by 'commands').
    def self.optional_commands(hash)
        hash.each do |name, path|
            name = symbolize(name)
            @origcommands[name] = path

            # Try to find the full path (or verify already-full paths); otherwise
            # store that the command is missing so we know it's defined but absent.
            if tmp = binary(path)
                path = tmp
                @commands[name] = path
            else
                @commands[name] = :missing
            end

            if block_given?
                yield(name, path)
            end

            # Now define the class and instance methods.
            make_command_methods(name)
        end
    end

    # Retrieve the data source.  Defaults to the provider name.
    def self.source
        unless defined? @source
            @source = self.name
        end
        @source
    end

    # Check whether this implementation is suitable for our platform.
    def self.suitable?(short = true)
        # A single false result is sufficient to turn the whole thing down.
        # We don't return 'true' until the very end, though, so that every
        # confine is tested.
        missing = {}
        @confines.each do |check, values|
            case check
            when :exists:
                values.each do |value|
                    unless value and FileTest.exists? value
                        debug "Not suitable: missing %s" % value
                        return false if short
                        missing[:exists] ||= []
                        missing[:exists] << value
                    end
                end
            when :true:
                values.each do |v|
                    debug "Not suitable: false value"
                    unless v
                        return false if short
                        missing[:true] ||= 0
                        missing[:true] += 1
                    end
                end
            when :false:
                values.each do |v|
                    debug "Not suitable: true value"
                    if v and short
                        return false if short
                        missing[:false] ||= 0
                        missing[:false] += 1
                    end
                end
            else # Just delegate everything else to facter
                if result = Facter.value(check)
                    result = result.to_s.downcase.intern

                    found = values.find do |v|
                        result == v.to_s.downcase.intern
                    end
                    unless found
                        debug "Not suitable: %s not in %s" % [check, values]
                        return false if short
                        missing[:facter] ||= {}
                        missing[:facter][check] = values
                    end
                else
                    return false if short
                    missing[:facter] ||= {}
                    missing[:facter][check] = values
                end
            end
        end

        if short
            return true
        else
            return missing
        end
    end

    # Does this provider support the specified parameter?
    def self.supports_parameter?(param)
        if param.is_a?(Class)
            klass = param
        else
            unless klass = resource_type.attrclass(param)
                raise Puppet::DevError, "'%s' is not a valid parameter for %s" % [param, resource_type.name]
            end
        end
        return true unless features = klass.required_features

        if satisfies?(*features)
            return true
        else
            return false
        end
    end

    def self.to_s
        unless defined? @str
            if self.resource_type
                @str = "%s provider %s" % [resource_type.name, self.name]
            else
                @str = "unattached provider %s" % [self.name]
            end
        end
        @str
    end

    dochook(:defaults) do
        if @defaults.length > 0
            return "  Default for " + @defaults.collect do |f, v|
                "``#{f}`` == ``#{v}``"
            end.join(" and ") + "."
        end
    end

    dochook(:commands) do
        if @origcommands.length > 0
            return "  Required binaries: " + @origcommands.collect do |n, c|
                "``#{c}``"
            end.join(", ") + "."
        end
    end

    dochook(:features) do
        if features().length > 0
            return "  Supported features: " + features().collect do |f|
                "``#{f}``"
            end.join(", ") + "."
        end
    end

    # Remove the reference to the resource, so GC can clean up.
    def clear
        @resource = nil
        @model = nil
    end

    # Retrieve a named command.
    def command(name)
        self.class.command(name)
    end

    # Get a parameter value.
    def get(param)
        @property_hash[symbolize(param)] || :absent
    end

    def initialize(resource = nil)
        if resource.is_a?(Hash)
            @property_hash = resource.dup
        elsif resource
            @resource = resource if resource
            # LAK 2007-05-09: Keep the model stuff around for backward compatibility
            @model = resource
            @property_hash = {}
        else
            @property_hash = {}
        end
    end

    def name
        if n = @property_hash[:name]
            return n
        elsif self.resource
            resource.name
        else
            raise Puppet::DevError, "No resource and no name in property hash"
        end
    end

    # Set passed params as the current values.
    def set(params)
        params.each do |param, value|
            @property_hash[symbolize(param)] = value
        end
    end

    def to_s
        "%s(provider=%s)" % [@resource.to_s, self.class.name]
    end
end

# $Id$
