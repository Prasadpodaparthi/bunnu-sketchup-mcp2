require "json"

module MCPforSketchUp
  module Handlers
    module Scenes
      P = Helpers::Paths
      V = Helpers::Validation
      DICT = "Bunnu_Structured_Scene_v1".freeze

      # Selection observers are opt-in through saved pose data. They never
      # apply geometry on load, attach, or a mere Scene property edit.
      class PoseObserver < (defined?(Sketchup::PagesObserver) ? Sketchup::PagesObserver : Object)
        def initialize(owner)
          @owner = owner
          @last_page = owner.pages.selected_page
        end

        def onContentsModified(pages)
          page = pages.selected_page
          return if page == @last_page
          @last_page = page
          return if Scenes.observers_suppressed? || !page
          return unless page.get_attribute(DICT, "managed", false)
          return if Scenes.poses(page).empty?
          ::UI.start_timer(0, false) do
            next unless Sketchup.active_model == @owner && pages.selected_page == page
            next if Scenes.observers_suppressed?
            begin
              Scenes.with_observers_suppressed do
                targets = Scenes.pose_targets(page)
                P.operation("Restore Scene Pose") { targets.each { |e, t| e.transformation = t } }
              end
            rescue StandardError => error
              Core::Logger.log("ERROR", "Scene pose was not applied: #{error.message}")
            end
          end
        end
      end

      class PoseAppObserver < (defined?(Sketchup::AppObserver) ? Sketchup::AppObserver : Object)
        def onOpenModel(owner); Scenes.attach_pose_observer(owner); end
        def onNewModel(owner); Scenes.attach_pose_observer(owner); end
        def onActivateModel(owner); Scenes.attach_pose_observer(owner); end
      end

      def self.observers_suppressed?
        @suppress_observers == true
      end

      def self.with_observers_suppressed
        previous = @suppress_observers
        @suppress_observers = true
        yield
      ensure
        @suppress_observers = previous
      end

      def self.attach_pose_observer(owner)
        return unless owner && owner.pages.respond_to?(:add_observer)
        @pose_observers ||= {}
        return if @pose_observers.key?(owner)
        observer = PoseObserver.new(owner)
        owner.pages.add_observer(observer)
        @pose_observers[owner] = observer
      end

      def self.install_pose_observers
        return if @app_observer
        @app_observer = PoseAppObserver.new
        Sketchup.add_observer(@app_observer)
        attach_pose_observer(Sketchup.active_model)
      end

      def self.model
        Helpers::Entities.active_model!
      end

      def self.find(id)
        pid = V.require_id({"id" => id})
        page = model.pages.find { |p| p.persistent_id == pid }
        P.fail!("scene #{pid} not found") unless page
        page
      end

      def self.describe(page)
        {"scene_id" => page.persistent_id, "name" => page.name,
         "description" => page.description, "active" => model.pages.selected_page == page,
         "camera" => Cameras.describe(page.camera), "use_camera" => page.use_camera?,
         "use_hidden_objects" => page.use_hidden_objects?, "use_hidden_layers" => page.use_hidden_layers?,
         "transition_time" => page.transition_time, "include_in_animation" => page.include_in_animation?,
         "poses" => poses(page), "managed" => page.get_attribute(DICT, "managed", false)}
      end

      def self.list_scenes(_params)
        {"scenes" => model.pages.map { |p| describe(p) }}
      end

      def self.poses(page)
        JSON.parse(page.get_attribute(DICT, "poses", "[]"))
      rescue JSON::ParserError
        P.fail!("invalid stored scene poses")
      end

      def self.pose_targets(page)
        data = poses(page)
        P.fail!("invalid stored scene poses") unless data.is_a?(Array) && data.length <= 500
        data.map do |item|
          P.fail!("invalid stored pose") unless item.is_a?(Hash)
          chain = P.writable!(P.resolve(item["instance_path"]))
          [chain.last, P.matrix(item["matrix_mm"])]
        end
      end

      def self.save_scene(params)
        page = params.key?("scene_id") ? find(params["scene_id"]) : nil
        name = params.key?("name") ? V.require_string(params, "name") : page&.name
        P.fail!("name is required for a new scene") unless name
        P.fail!("another scene already has this name") if model.pages.any? { |p| p != page && p.name == name }
        capture = V.optional_bool(params, "capture_current", page.nil?)
        camera = if params.key?("camera")
                   Cameras.build(params["camera"])
                 elsif capture
                   Cameras.clone_camera(Cameras.view.camera)
                 end
        overrides = params.fetch("visibility", [])
        P.fail!("visibility must be an array of at most 500 overrides") unless overrides.is_a?(Array) && overrides.length <= 500
        visibility = overrides.map do |item|
          P.fail!("visibility override must be an object") unless item.is_a?(Hash)
          chain = P.writable!(P.resolve(item["instance_path"]))
          visible = V.optional_bool(item, "visible", true)
          [chain.last, visible]
        end
        pose_data = if params.key?("pose_paths")
                      params["pose_paths"] == [] ? [] : P.paths(params["pose_paths"], "pose_paths").map do |chain|
                        P.writable!(chain)
                        {"instance_path" => P.key(chain), "matrix_mm" => P.matrix_mm(chain.last.transformation)}
                      end
                    end
        transition = params.key?("transition_time") ? P.finite_vector([params["transition_time"]], 1, "transition_time").first : nil
        P.fail!("transition_time must be nonnegative") if transition && transition < 0
        animation = V.optional_bool(params, "include_in_animation", true)
        with_observers_suppressed do
          P.operation("Save Scene") do
            unless page
              page = model.pages.add(name)
              # These tools capture camera, object/tag visibility and rendering.
              # Disable other native Scene properties rather than inherit them.
              %w[axes section_planes shadow_info style hidden_geometry environment].each do |flag|
                writer = "use_#{flag}="
                page.public_send(writer, false) if page.respond_to?(writer)
              end
            end
            page.name = name
            page.description = V.require_string(params, "description") if params.key?("description")
            # Explicit capture updates only camera, visibility, and rendering.
            # Renaming an existing Scene does not recapture its camera/settings.
            if capture
              page.use_camera = true
              page.use_hidden_objects = true
              page.use_hidden_layers = true
              page.use_rendering_options = true
              page.update(PAGE_USE_CAMERA | PAGE_USE_HIDDEN_OBJECTS | PAGE_USE_LAYER_VISIBILITY | PAGE_USE_RENDERING_OPTIONS)
            end
            if capture || params.key?("camera")
              page.camera.set(camera.eye, camera.target, camera.up)
              page.camera.perspective = camera.perspective?
              page.camera.aspect_ratio = camera.aspect_ratio
              camera.perspective? ? page.camera.fov = camera.fov : page.camera.height = camera.height
              page.use_camera = true
            end
            unless visibility.empty?
              page.use_hidden_objects = true
              visibility.each { |entity, visible| page.set_drawingelement_visibility(entity, visible) }
            end
            page.transition_time = transition if transition
            page.include_in_animation = animation if params.key?("include_in_animation") || !params.key?("scene_id")
            page.set_attribute(DICT, "managed", true)
            page.set_attribute(DICT, "poses", JSON.generate(pose_data)) unless pose_data.nil?
            describe(page)
          end
        end
      end

      # Snapshots only references/state; never creates alternate geometry.
      def self.folders(owner = model.layers)
        return [] unless owner.respond_to?(:folders)
        owner.folders.flat_map { |folder| [folder] + folders(folder) }
      end

      def self.drawing_elements
        entities = model.entities.select { |e| e.respond_to?(:hidden?) }
        P.walk([], max_depth: 64) { |chain| entities << chain.last }
        entities.uniq
      end

      def self.snapshot(page = nil)
        {camera: Cameras.clone_camera(Cameras.view.camera),
         hidden: drawing_elements.map { |e| [e, e.hidden?] },
         layers: model.layers.map { |l| [l, l.visible?] },
         folders: folders.map { |f| [f, f.visible?] },
         rendering: model.rendering_options.to_a,
         poses: page ? pose_targets(page).map { |e, _| [e, e.transformation] } : []}
      end

      def self.restore(snapshot)
        snapshot[:poses].each { |e, t| e.transformation = t }
        snapshot[:hidden].each { |e, value| e.hidden = value }
        snapshot[:layers].each { |l, value| l.visible = value }
        snapshot[:folders].each { |f, value| f.visible = value }
        write_rendering(snapshot[:rendering])
        Cameras.view.camera = snapshot[:camera]
        Cameras.view.refresh
      end

      def self.write_rendering(options)
        options.each do |k, v|
          # Do not assign unchanged read-only API properties.
          model.rendering_options[k] = v unless model.rendering_options[k] == v
        end
      end

      def self.apply(page, select: true)
        targets = pose_targets(page) # validate ALL paths before applying any pose
        if select
          old_time = page.transition_time
          begin
            page.transition_time = 0
            model.pages.selected_page = page
          ensure
            page.transition_time = old_time
          end
        else
          # For capture, use managed scenes only: unsupported native flags must
          # not silently produce an incorrect screenshot or alter section state.
          unsupported = %w[axes section_planes shadow_info style hidden_geometry environment].select do |flag|
            reader = "use_#{flag}?"
            page.respond_to?(reader) && page.public_send(reader)
          end
          P.fail!("scene capture cannot restore these properties: #{unsupported.join(', ')}") unless unsupported.empty?
          drawing_elements.each do |e|
            e.hidden = !page.get_drawingelement_visibility(e) if page.use_hidden_objects?
          end
          if page.use_hidden_layers?
            overrides = page.layers
            model.layers.each do |l|
              next if l == model.layers[0]
              hidden_default = (l.page_behavior & LAYER_HIDDEN_BY_DEFAULT) != 0
              l.visible = (overrides.include?(l) == hidden_default)
            end
            hidden_folders = page.layer_folders || []
            folders.each { |f| f.visible = !hidden_folders.include?(f) }
          end
          write_rendering(page.rendering_options) if page.use_rendering_options?
        end
        targets.each { |e, t| e.transformation = t }
        Cameras.view.camera = Cameras.clone_camera(page.camera) if page.use_camera?
        Cameras.view.refresh
      end

      def self.activate_scene(params)
        page = find(params["scene_id"])
        with_observers_suppressed do
          P.operation("Activate Scene") { apply(page); describe(page).merge("ready" => true) }
        end
      end

      def self.delete_scene(params)
        page = find(params["scene_id"])
        P.operation("Delete Scene") do
          model.pages.erase(page)
          {"ok" => true, "scene_id" => params["scene_id"]}
        end
      end
    end
  end
end
