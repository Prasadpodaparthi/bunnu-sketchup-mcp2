# Explicit occurrence addressing. Paths contain persistent IDs, never entityIDs.
module MCPforSketchUp
  module Helpers
    module Paths
      E = Entities
      V = Validation
      Error = Core::StructuredError
      MAX_DEPTH = 64

      def self.fail!(message)
        raise Error.new(-32602, message)
      end

      def self.parse(value, root: false)
        return [] if root && value == ""
        fail!("instance_path must be a dot-separated persistent-ID path") unless
          value.is_a?(String) && value.match?(/\A[1-9]\d*(?:\.[1-9]\d*)*\z/)
        ids = value.split(".").map(&:to_i)
        fail!("instance_path exceeds #{MAX_DEPTH} levels") if ids.length > MAX_DEPTH
        ids
      end

      def self.key(chain)
        chain.map(&:persistent_id).join(".")
      end

      def self.collection(chain)
        chain.empty? ? E.active_model!.entities : chain.last.definition.entities
      end

      def self.resolve(value, root: false)
        chain = []
        parse(value, root: root).each do |pid|
          entity = collection(chain).find { |item| item.valid? && item.persistent_id == pid }
          fail!("stale or invalid instance_path: #{value}") unless entity
          E.require_group_or_component!(entity)
          chain << entity
        end
        chain
      end

      # Editing a child changes its parent's definition. Reject every shared
      # ancestor, not just the leaf. No implicit make_unique or sibling edits.
      def self.writable!(chain, contents: false)
        chain.each { |e| fail!("locked instance in path #{key(chain)}") if e.locked? }
        ancestors = contents ? chain : chain[0...-1]
        ancestors.each do |e|
          fail!("shared ancestor #{e.persistent_id}; use an independent assembly") if
            e.definition.instances.count { |i| i.valid? } > 1
        end
        chain
      end

      def self.world(chain)
        chain.inject(Geom::Transformation.new) { |t, e| t * e.transformation }
      end

      def self.finite_vector(value, size, field)
        fail!("#{field} must contain #{size} finite numbers") unless
          value.is_a?(Array) && value.length == size &&
          value.all? { |v| v.is_a?(Numeric) && v.finite? }
        value.map(&:to_f)
      end

      def self.matrix(value)
        a = finite_vector(value, 16, "matrix_mm")
        fail!("matrix_mm must be affine, column-major, with last row [0,0,0,1]") unless
          [3, 7, 11].all? { |i| a[i].abs < 1e-12 } && (a[15] - 1).abs < 1e-12
        det = a[0]*(a[5]*a[10]-a[9]*a[6]) - a[4]*(a[1]*a[10]-a[9]*a[2]) + a[8]*(a[1]*a[6]-a[5]*a[2])
        fail!("matrix_mm is singular") if det.abs <= 1e-12
        [12, 13, 14].each { |i| a[i] /= 25.4 }
        Geom::Transformation.new(a)
      end

      def self.matrix_mm(t)
        a = t.to_a
        [12, 13, 14].each { |i| a[i] *= 25.4 }
        a
      end

      def self.bounds(chain, transform = world(chain))
        local = chain.last.definition.bounds
        return nil if Geometry.empty_bbox?(local)
        bb = Geom::BoundingBox.new
        8.times { |i| bb.add(transform * local.corner(i)) }
        bb
      end

      def self.describe(chain)
        e = chain.last
        bb = bounds(chain)
        {
          "id" => e.entityID, "persistent_id" => e.persistent_id,
          "instance_path" => key(chain), "parent_path" => key(chain[0...-1]),
          "definition_id" => e.definition.persistent_id,
          "name" => e.name, "type" => e.is_a?(Sketchup::Group) ? "group" : "component",
          "layer" => e.layer.name, "depth" => chain.length - 1,
          "transform_local_mm" => matrix_mm(e.transformation),
          "transform_world_mm" => matrix_mm(world(chain)),
          "bbox_mm" => bb && {"min" => bb.min.to_a.map { |v| v * 25.4 },
                              "max" => bb.max.to_a.map { |v| v * 25.4 }}
        }
      end

      def self.walk(parent = [], max_depth: 10, depth: 0, seen: [], &block)
        return if depth > max_depth
        collection(parent).each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          chain = parent + [e]
          yield chain
          next if seen.include?(e.definition)
          walk(chain, max_depth: max_depth, depth: depth + 1, seen: seen + [e.definition], &block)
        end
      end

      def self.target(params)
        unless params.key?("instance_path")
          id = V.require_id(params)
          matches = []
          walk([], max_depth: MAX_DEPTH) { |c| matches << c if c.last.entityID == id }
          fail!("id must resolve to exactly one occurrence; provide instance_path") unless matches.length == 1
          return matches.first
        end
        chain = resolve(V.require_string(params, "instance_path"))
        if params.key?("id") && chain.last.entityID != V.require_id(params)
          fail!("id does not match instance_path")
        end
        chain
      end

      def self.creation_context(params)
        return nil unless params.key?("parent_path")
        parent = writable!(resolve(params["parent_path"], root: true), contents: true)
        space = V.optional_enum(params, "coordinate_space", %w[parent world], "parent")
        {parent: parent, entities: collection(parent), space: space}
      end

      def self.finish_creation(group, context)
        return unless context
        group.transformation = world(context[:parent]).inverse * group.transformation if context[:space] == "world"
        describe(context[:parent] + [group])
      end

      def self.paths(value, field = "entity_paths")
        fail!("#{field} must contain 1..500 unique paths") unless
          value.is_a?(Array) && value.length.between?(1, 500) && value.uniq.length == value.length
        chains = value.map { |path| resolve(path) }
        chains.combination(2) do |a, b|
          fail!("#{field} cannot contain both an ancestor and its descendant") if
            a[0, b.length] == b || b[0, a.length] == a
        end
        chains
      end

      def self.operation(name)
        model = E.active_model!
        model.start_operation(name, true)
        begin
          result = yield
          model.commit_operation
          result
        rescue StandardError
          model.abort_operation
          raise
        end
      end
    end
  end
end
