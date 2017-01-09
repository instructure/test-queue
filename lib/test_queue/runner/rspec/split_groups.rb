require_relative "group_queue"

class TestQueue::Runner::RSpec
  module SplitGroups
    module GroupResolver
      # enhance the group resolver to reserve intermediate groups
      # and the target example
      def [](keys)
        keys = keys.dup
        key = keys.shift.pop
        group = fetch(key) or return nil
        group.reserve_items(keys)
        group
      end
    end

    module Runner
      # A given runner can set a preferred_tag, and it will ask for those
      # matching ExampleGroups from the master before it works on any others
      #
      # Example:
      #
      #   class MyRunner < TestQueue::Runner::RSpec
      #     def after_fork(num)
      #       if num == 1
      #         # make the first worker work exclusively on no_split
      #         # groups, until they are done, at which point it will do
      #         # whatever
      #         self.preferred_tag = [:no_split, true]
      #       end
      #     end
      #
      # Note: only the `no_split` metadata is supported by default, but you
      # can add other ones like so:
      #
      #   TestQueue::Runner::RSpec::GroupQueue::TRACKED_METADATA << :feature
      attr_accessor :preferred_tag

      def prepare_queue(queue)
        @queue = queue.map { |item| [:group, item.to_s] }
        @suites = TestQueue::Runner::RSpec::GroupResolver.new(queue)
        queue.each do |group|
          group.descendants.each do |subgroup|
            add_group_queue GroupQueue.for(subgroup, stats)
          end
        end
      end

      def run_worker(iterator)
        # so that groups can ask it for the next item from their queues
        QueueStrategy::Enumerator.iterator = iterator
        super
      end

      # Maintain a counter so we have a cheap way to know if there are any
      # examples left in any (sub)group
      attr_writer :example_queue_size
      def example_queue_size
        @example_queue_size ||= 0
      end

      def add_group_queue(queue)
        self.example_queue_size += queue.num_examples
        super
      end

      def queue_empty?
        # @queue can empty out while the very last examples are being
        # worked on; wait till they are done so we don't abandon any
        # live workers
        super && example_queue_size == 0
      end

      def normalize_scope(scope)
        scope
      end

      # Pop the next item (example or group) directly under the given
      # scope. If we pop a group, also recursively pop sub-items till we
      # get an example. This way we can avoid race conditions and ensure
      # that we don't run a context-level hooks only to have examples
      # pulled out underneath us.
      #
      # Returns nil if there are no more examples in this scope, otherwise
      # any array containing zero or more intermediate group keys and the
      # example key they resolve to.
      def pop_next(scope, preferred_tag: nil)
        queue = if scope
          scope = normalize_scope(scope)
          group_queues[scope].queue
        else
          @queue
        end

        while best = best_item(queue, preferred_tag)
          return best if best.is_a?(::Symbol) # e.g. :wait
          type, item = best
          # woot, direct child example
          if type == :example
            self.example_queue_size -= 1
            return [[type, item]]
          end

          # woot, group with a descendant example
          if subitems = pop_next(item)
            # if the group is eligible for splitting, throw it to the back of the queue so
            # another worker can potentially come help
            key = normalize_scope(item)
            sub_queue = group_queues[key] || raise("don't know what #{key.inspect} is (item is #{item.inspect}, best is #{best.inspect})")
            can_split = !sub_queue.tags[:no_split]
            has_more = !sub_queue.empty?
            below_split_threshold = split_counts[key] < max_splits_per_group

            if can_split && has_more && below_split_threshold
              split_counts[item] += 1
              queue << [type, item]
            end

            return [[type, item]] + subitems
          end

          # otherwise we're hitting already-completed groups, just discard
          # them until we find something or exhaust the queue
        end

        nil
      end

      def best_item(queue, preferred_tag)
        return queue.shift unless preferred_tag

        tag, val = preferred_tag
        if index = queue.index { |type, item| group_queues[normalize_scope(item)].tags[tag] == val }
          queue.delete_at(index)
        else
          queue.shift
        end
      end

      def split_counts
        @split_counts ||= Hash.new(0)
      end

      # put an upper bound on how much splitting we do for a given group,
      # so we can avoid diminishing returns
      def max_splits_per_group
        @max_splits_per_group ||= ENV.fetch("TEST_QUEUE_MAX_SPLITS_PER_GROUP", 20).to_i
      end

      def handle_command(cmd, sock)
        case cmd
        when /^POP/
          scope = nil
          preferred_tag = nil
          if cmd =~ /^POP ITEM (\d+)/
            data = sock.read($1.to_i)
            scope = Marshal.load(data)
          elsif cmd =~ /^POP TAGGED (\d+)/
            preferred_tag = Marshal.load(sock.read($1.to_i))
          end
          if keys = pop_next(scope, preferred_tag: preferred_tag)
            data = Marshal.dump(keys)
            sock.write(data)
          end
        else
          super
        end
      end
    end

    module Iterator
      def query(payload)
        if payload == "POP\n" && @runner.preferred_tag
          tag = ::Marshal.dump(@runner.preferred_tag)
          payload = "POP TAGGED #{tag.bytesize}\n#{tag}"
        end
        super payload
      end

      def pop(group)
        group = ::Marshal.dump(group)
        query("POP ITEM #{group.bytesize}\n#{group}")
      end

      def capture_timing(item)
        # for examples or no_split groups, we capture the total time, since
        # it will take at least that long
        return super(item.full_description) if item.is_a?(::RSpec::Core::Example)
        return super if item.metadata[:no_split]

        # otherwise we just capture the time of our context hooks plus the
        # time of the slowest child in the group (a subgroup or example)
        result = yield
        slowest_child_time = item.filtered_items_hash.
          values.
          map(&:keys).
          flatten.
          map { |key| @stats[key] || 0 }.
          max || 0
        @stats[item.to_s] = item.hook_time + slowest_child_time
        result
      end
    end

    class QueueStrategy
      def initialize(group)
        @group = group
        @enumerator = Enumerator.new(group)
      end

      def order(items)
        @enumerator
      end

      class Enumerator
        class << self
          attr_accessor :iterator
        end

        attr_reader :group
        attr_reader :example_block

        def initialize(group)
          @group = group
        end

        def iterator
          self.class.iterator
        end

        # called first for examples, do nothing and save block.
        # called again for groups ... start pulling off interleaved
        # examples and groups, calling the appropriate block.
        def map
          block = Proc.new
          if !@example_block
            @example_block = block
            return []
          else
            @group_block = block
          end

          result = []
          if item = group.reserved_item
            group.reserved_item = nil
            result << run_item(item)
          end

          while keys = iterator.pop(group.to_s)
            # direct child group or example
            pair = keys.shift
            subtype, key = pair
            item = group.filtered_items_hash[subtype][key]

            # if a group, we need to reserve the specified descendant example
            # and any intermediate groups
            item.reserve_items(keys) if subtype == :group
            result << run_item(item)
          end
          result
        end

        def run_item(item)
          block = item.is_a?(::RSpec::Core::Example) ? @example_block : @group_block
          iterator.capture_timing(item) do
            block.call(item)
          end
        end
      end
    end

    module Extensions
      module ExampleGroup
        attr_accessor :reserved_item

        def reserve_items(keys)
          keys.inject(self) do |group, pair|
            type, key = pair
            group.reserved_item = group.filtered_items_hash[type][key]
          end
        end

        # RSpec uses this twice; first for examples, then for groups.
        # We basically make run_example a no-op and then do everything
        # in the second call to #map ... examples and groups are
        # interleaved, with the slowest ones first
        def ordering_strategy
          @ordering_strategy ||= QueueStrategy.new(self)
        end

        def run_before_context_hooks(*)
          capture_hook_time { super }
        end

        def run_after_context_hooks(*)
          capture_hook_time { super }
        end

        attr_reader :hook_time
        def capture_hook_time
          start = Time.now
          result = yield
          @hook_time ||= 0
          @hook_time += Time.now - start
          result
        end
      end
    end
  end

  prepend SplitGroups::Runner
  GroupResolver.prepend SplitGroups::GroupResolver
  ::TestQueue::Iterator.prepend SplitGroups::Iterator
  ::RSpec::Core::ExampleGroup.singleton_class.prepend SplitGroups::Extensions::ExampleGroup
end
