module MCPforSketchUp
  module Handlers
    module Assemblies
      P = Helpers::Paths
      V = Helpers::Validation

      def self.copy_properties(source, copy)
        copy.name = source.name
        copy.layer = source.layer
        copy.material = source.material
        copy.hidden = source.hidden?
        copy.casts_shadows = source.casts_shadows?
        copy.receives_shadows = source.receives_shadows?
        source.attribute_dictionaries&.each do |dict|
          dict.each_pair { |k, v| copy.set_attribute(dict.name, k, v) }
        end
      end

      # Retain Group type without converting or editing the source definition.
      # Only the temporary inner instance is exploded, inside a fresh container.
      def self.copy_into(source, entities, transform)
        if source.is_a?(Sketchup::Group)
          copy = entities.add_group
          inserted = copy.entities.add_instance(source.definition, Geom::Transformation.new)
          result = inserted.explode
          P.fail!("failed to copy group contents") unless result
          copy.transformation = transform
        else
          copy = entities.add_instance(source.definition, transform)
        end
        copy_properties(source, copy)
        copy
      end

      def self.check_destination!(sources, parent)
        P.writable!(parent, contents: true)
        sources.each do |chain|
          P.writable!(chain)
          P.fail!("cannot move an assembly into itself or a descendant") if parent[0, chain.length] == chain
          # Definition recursion can occur even through different instances.
          descendants = [chain.last.definition]
          P.walk(chain, max_depth: 64) { |c| descendants << c.last.definition }
          P.fail!("destination would create a recursive definition") if parent.any? { |e| descendants.include?(e.definition) }
        end
      end

      def self.reparent_entities(params)
        sources = P.paths(params["entity_paths"])
        parent = P.resolve(params.fetch("parent_path", ""), root: true)
        preserve = V.optional_bool(params, "preserve_world_transform", true)
        check_destination!(sources, parent)
        P.operation("Reparent Assemblies") do
          mapped = sources.map do |chain|
            if chain[0...-1] == parent
              {"old_path" => P.key(chain), "entity" => P.describe(chain)}
            else
              transform = preserve ? P.world(parent).inverse * P.world(chain) : chain.last.transformation
              copy = copy_into(chain.last, P.collection(parent), transform)
              old = P.key(chain)
              chain.last.erase!
              {"old_path" => old, "entity" => P.describe(parent + [copy])}
            end
          end
          {"entities" => mapped, "refresh_descendant_paths" => true}
        end
      end

      def self.create_assembly(params)
        name = V.require_string(params, "name")
        kind = V.optional_enum(params, "kind", %w[group component], "group")
        sources = P.paths(params["member_paths"], "member_paths")
        parent = P.resolve(params.fetch("parent_path", ""), root: true)
        check_destination!(sources, parent)
        P.operation("Create Assembly") do
          group = P.collection(parent).add_group
          children = sources.map do |chain|
            t = P.world(parent).inverse * P.world(chain)
            copy = copy_into(chain.last, group.entities, t)
            old = P.key(chain)
            chain.last.erase!
            [old, copy]
          end
          assembly = kind == "component" ? group.to_component : group
          assembly.name = name
          {"assembly" => P.describe(parent + [assembly]),
           "members" => children.map { |old, copy| {"old_path" => old, "entity" => P.describe(parent + [assembly, copy])} },
           "refresh_descendant_paths" => true}
        end
      end

      def self.duplicate_component(params)
        source = P.target(params)
        parent = P.resolve(params.fetch("parent_path", ""), root: true)
        P.writable!(parent, contents: true)
        check_destination!([source], parent)
        mode = V.optional_enum(params, "definition_mode", %w[shared unique], "unique")
        P.fail!("shared duplication requires a ComponentInstance") if mode == "shared" && source.last.is_a?(Sketchup::Group)
        transform = params.key?("matrix_mm") ? P.matrix(params["matrix_mm"]) : P.world(parent).inverse * P.world(source)
        name = V.require_string(params, "name")
        P.operation("Duplicate Assembly") do
          copy = copy_into(source.last, P.collection(parent), transform)
          if mode == "unique"
            make_tree_unique(copy)
          end
          copy.name = name
          P.describe(parent + [copy])
        end
      end

      def self.make_tree_unique(entity, depth = 0)
        P.fail!("assembly exceeds 64 levels") if depth > 64
        entity.make_unique
        entity.definition.entities.each do |child|
          make_tree_unique(child, depth + 1) if child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
      end

      def self.transform_component(params)
        chain = P.writable!(P.target(params))
        entity = chain.last
        space = V.optional_enum(params, "coordinate_space", %w[parent world local], "parent")
        fields = %w[position rotation scale translation_mm pivot_mm axis angle_degrees]
        if params.key?("matrix_mm")
          P.fail!("matrix_mm cannot be combined with relative transforms") if fields.any? { |k| params.key?(k) }
          P.fail!("absolute matrix uses parent or world space") if space == "local"
          desired = P.matrix(params["matrix_mm"])
          desired = P.world(chain[0...-1]).inverse * desired if space == "world"
        else
          # basis maps coordinates in the requested space into the parent frame.
          basis = case space
                  when "world" then P.world(chain[0...-1]).inverse
                  when "local" then entity.transformation
                  else Geom::Transformation.new
                  end
          initial = basis.inverse * entity.transformation
          bb = P.bounds(chain, initial)
          P.fail!("cannot relatively transform an empty assembly") unless bb
          pivot = params.key?("pivot_mm") ? point(params["pivot_mm"], "pivot_mm") : bb.center
          transform = Geom::Transformation.new
          if params.key?("axis") || params.key?("angle_degrees")
            P.fail!("axis and angle_degrees are required together; omit rotation") unless
              params.key?("axis") && params.key?("angle_degrees") && !params.key?("rotation")
            axis = P.finite_vector(params["axis"], 3, "axis")
            P.fail!("axis must be nonzero") if axis.sum { |x| x*x } <= 1e-18
            angle = P.finite_vector([params["angle_degrees"]], 1, "angle_degrees").first
            transform = Geom::Transformation.rotation(pivot, Geom::Vector3d.new(*axis), angle * Math::PI / 180)
          elsif params.key?("rotation")
            P.finite_vector(params["rotation"], 3, "rotation").each_with_index do |angle, i|
              axis = [0, 0, 0]; axis[i] = 1
              transform = Geom::Transformation.rotation(pivot, Geom::Vector3d.new(*axis), angle * Math::PI / 180) * transform
            end
          end
          if params.key?("scale")
            scale = P.finite_vector(params["scale"], 3, "scale")
            P.fail!("scale must be nonzero") if scale.any? { |v| v.abs <= 1e-9 }
            transform = Geom::Transformation.scaling(pivot, *scale) * transform
          end
          desired = transform * initial
          if params.key?("translation_mm")
            delta = point(params["translation_mm"], "translation_mm").to_a
            desired = Geom::Transformation.translation(delta) * desired
          end
          if params.key?("position")
            target = point(params["position"], "position")
            moved = P.bounds(chain, desired)
            desired = Geom::Transformation.translation(target - moved.min) * desired
          end
          desired = basis * desired
        end
        P.operation("Transform Assembly") do
          entity.transformation = desired
          P.describe(chain)
        end
      end

      def self.point(value, field)
        Geom::Point3d.new(*P.finite_vector(value, 3, field).map { |v| v / 25.4 })
      end
    end
  end
end
