=begin rdoc
  Adds a bash alias
=end
module PoolParty
  module Resources
    class BashAlias < Resource
      dsl_methods :name,  # the name of the cmd
                  :value, # the value of the alias
                  :user 

      def before_load(opts={}, &block)
        # TODO, why does "has_" segfault
        line_in_file :file => "/root/.profile", :line => "alias #{opts[:name]}='#{opts[:value]}'"
      end
    end
  end
end
