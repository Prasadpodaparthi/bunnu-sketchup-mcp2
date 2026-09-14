module MCPforSketchUp
  module Handlers
    module Cameras
      P = Helpers::Paths
      V = Helpers::Validation

      def self.view
        result = Helpers::Entities.active_model!.active_view
        P.fail!("no active viewport") unless result && result.vpwidth > 0 && result.vpheight > 0
        result
      end

      def self.describe(camera = view.camera)
        result = {"eye_mm" => camera.eye.to_a.map { |v| v * 25.4 },
                  "target_mm" => camera.target.to_a.map { |v| v * 25.4 },
                  "up" => camera.up.to_a,
                  "projection" => camera.perspective? ? "perspective" : "parallel",
                  "aspect_ratio" => camera.aspect_ratio,
                  "viewport_aspect_ratio" => view.vpwidth.to_f / view.vpheight,
                  "is_2d" => camera.is_2d?}
        if camera.perspective?
          result["fov_degrees"] = camera.fov
          result["fov_axis"] = camera.fov_is_height? ? "vertical" : "horizontal"
        else
          result["height_mm"] = camera.height * 25.4
        end
        result
      end

      def self.clone_camera(camera)
        P.fail!("two-point perspective / match-photo cameras are unsupported") if camera.is_2d?
        copy = Sketchup::Camera.new(camera.eye, camera.target, camera.up, camera.perspective?)
        copy.aspect_ratio = camera.aspect_ratio
        copy.image_width = camera.image_width
        camera.perspective? ? copy.fov = camera.fov : copy.height = camera.height
        copy
      end

      def self.build(spec)
        P.fail!("camera must be an object") unless spec.is_a?(Hash)
        eye = Assemblies.point(spec["eye_mm"], "eye_mm")
        target = Assemblies.point(spec["target_mm"], "target_mm")
        up = Geom::Vector3d.new(*P.finite_vector(spec["up"], 3, "up"))
        direction = target - eye
        P.fail!("camera basis is degenerate") if direction.length <= 1e-9 || up.length <= 1e-9 || direction.cross(up).length <= 1e-9
        projection = V.optional_enum(spec, "projection", %w[perspective parallel], "perspective")
        camera = Sketchup::Camera.new(eye, target, up, projection == "perspective")
        if camera.perspective?
          fov = P.finite_vector([spec.fetch("fov_degrees", 35)], 1, "fov_degrees").first
          P.fail!("fov_degrees must be between 1 and 120") unless fov.between?(1, 120)
          camera.fov = fov
        else
          height = P.finite_vector([spec.fetch("height_mm", 1000)], 1, "height_mm").first
          P.fail!("height_mm must be positive") unless height > 0
          camera.height = height / 25.4
        end
        camera
      end

      def self.resolve(params)
        if params.key?("camera")
          P.fail!("camera cannot be combined with preset/framing/projection") if
            %w[view_preset frame_paths projection margin].any? { |k| params.key?(k) }
          return build(params["camera"])
        end
        preset = V.optional_enum(params, "view_preset", View::ALLOWED_PRESETS, "current")
        projection = V.optional_enum(params, "projection", %w[perspective parallel])
        margin = P.finite_vector([params.fetch("margin", 1.1)], 1, "margin").first
        P.fail!("margin must be between 1 and 10") unless margin.between?(1, 10)
        bb = if params.key?("frame_paths")
               bounds = Geom::BoundingBox.new
               P.paths(params["frame_paths"], "frame_paths").each do |chain|
                 b = P.bounds(chain)
                 bounds.add(b.min, b.max) if b
               end
               P.fail!("framing targets have no geometry") if Helpers::Geometry.empty_bbox?(bounds)
               bounds
             else
               Helpers::Geometry.visible_bounds(Helpers::Entities.active_model!)
             end
        camera = preset == "current" ? clone_camera(view.camera) : View.build_preset_camera(preset, bb, view.camera)
        camera.perspective = projection == "perspective" if projection
        if params.key?("frame_paths") || preset != "current"
          # Fit a bounding sphere to BOTH viewport dimensions, including narrow views.
          radius = [bb.diagonal / 2.0, 0.001].max * margin
          aspect = view.vpwidth.to_f / view.vpheight
          direction = camera.eye - camera.target
          if camera.perspective?
            half = camera.fov * Math::PI / 360
            other = camera.fov_is_height? ? Math.atan(Math.tan(half) * aspect) : Math.atan(Math.tan(half) / aspect)
            distance = radius / Math.sin([half, other].min)
          else
            camera.height = 2 * radius / [aspect, 1.0].min
            distance = 3 * radius
          end
          direction.length = distance
          camera.set(bb.center + direction, bb.center, camera.up)
        end
        camera
      end

      def self.get_camera(_params)
        describe
      end

      def self.set_camera(params)
        camera = resolve(params)
        view.camera = camera
        view.refresh
        describe
      end

      def self.screenshot(params)
        # Capture a Scene's camera/visibility/poses without selecting its tab.
        # This avoids asynchronous native scene transitions during write_image.
        restore = V.optional_bool(params, "restore_view", true)
        page = params.key?("scene_id") ? Scenes.find(params["scene_id"]) : nil
        P.fail!("scene_id cannot be combined with camera/framing/preset overrides") if page &&
          (%w[camera frame_paths projection margin].any? { |k| params.key?(k) } || params.fetch("view_preset", "current") != "current")
        P.fail!("zoom_extents conflicts with explicit scene/camera/framing") if params["zoom_extents"]
        snapshot = Scenes.snapshot(page)
        model = Helpers::Entities.active_model!
        model.start_operation("Capture Structured View", true)
        completed = false
        begin
          if page
            Scenes.apply(page, select: false)
          else
            opts = params.select { |k, _| %w[camera frame_paths projection margin view_preset].include?(k) }
            opts.delete("view_preset") if opts["view_preset"] == "current" && opts.key?("camera")
            view.camera = resolve(opts)
          end
          effective = describe
          basic = params.reject { |k, _| %w[scene_id camera frame_paths projection margin].include?(k) }
          result = View.viewport_screenshot(basic.merge("view_preset" => "current", "restore_view" => false))
          completed = true
          result.merge("camera" => effective, "scene_id" => page&.persistent_id)
        ensure
          if restore || !completed
            begin
              Scenes.restore(snapshot)
            ensure
              # A restoring capture leaves no geometry/visibility undo entry.
              model.abort_operation
            end
            Cameras.view.camera = snapshot[:camera]
          else
            model.commit_operation
          end
        end
      end
    end
  end
end
