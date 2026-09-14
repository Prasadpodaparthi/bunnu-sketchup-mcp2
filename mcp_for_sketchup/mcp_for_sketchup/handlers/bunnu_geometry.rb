# Bunnu custom geometry handlers.
#
# These handlers extend sketchup-mcp2 with geometry capabilities
# that are intentionally kept separate from the upstream primitives.

module MCPforSketchUp
  module Handlers
    module BunnuGeometry
      E = MCPforSketchUp::Helpers::Entities

      # Create a visually smooth 3D curve from control points.
      #
      # Input coordinates are millimetres.
      #
      # The control points are interpolated using a controlled
      # cubic Hermite spline before being passed to SketchUp's
      # add_curve.
      #
      # The tangent calculation is limited so the generated curve
      # does not unnecessarily overshoot the control-point envelope.
      def self.create_curve(params)
        points = params["points"]
        closed = params.fetch("closed", false)
        name = params["name"]
        samples = params.fetch("samples", 12).to_i

        validate_points!(points)
        validate_closed!(closed)
        validate_samples!(samples)

        context = Helpers::Paths.creation_context(params) if params.key?("parent_path")
        model = E.active_model!

        model.start_operation("Bunnu Create Curve", true)

        begin
          group = (context ? context[:entities] : model.active_entities).add_group

          control_points = points.map do |point|
            Geom::Point3d.new(
              point[0].to_f.mm,
              point[1].to_f.mm,
              point[2].to_f.mm
            )
          end

          curve_points = controlled_spline_points(
            control_points,
            closed,
            samples
          )

          group.entities.add_curve(curve_points)

          group.name = name.to_s if name && !name.to_s.empty?

          hierarchy = Helpers::Paths.finish_creation(group, context) if context
          model.commit_operation

          bbox = group.bounds

          result = {
            "id" => group.entityID,
            "name" => group.name,
            "type" => "curve",
            "closed" => closed,
            "point_count" => points.length,
            "generated_point_count" => curve_points.length,
            "samples" => samples,
            "bbox_mm" => {
              "min" => [
                bbox.min.x.to_mm,
                bbox.min.y.to_mm,
                bbox.min.z.to_mm
              ],
              "max" => [
                bbox.max.x.to_mm,
                bbox.max.y.to_mm,
                bbox.max.z.to_mm
              ]
            }
          }
          hierarchy ? result.merge(hierarchy) : result
        rescue StandardError
          model.abort_operation
          raise
        end
      end

      # Create a true circular curve.
      #
      # Input coordinates and radius are millimetres.
      #
      # The circle is created directly with SketchUp's native
      # add_circle API rather than spline interpolation.
      def self.create_circle(params)
        center = params["center"]
        radius = params["radius"]
        normal = params.fetch("normal", [0, 0, 1])
        segments = params.fetch("segments", 96).to_i
        name = params["name"]

        validate_vector3!(center, "center")
        validate_vector3!(normal, "normal")

        unless radius.is_a?(Numeric) && radius.to_f > 0
          raise MCPforSketchUp::Core::StructuredError.new(
            code: -32602,
            message: "radius must be a positive number",
            data: { "field" => "radius" }
          )
        end

        validate_circle_segments!(segments)

        context = Helpers::Paths.creation_context(params) if params.key?("parent_path")
        model = E.active_model!

        model.start_operation("Bunnu Create Circle", true)

        begin
          group = (context ? context[:entities] : model.active_entities).add_group

          center_point = Geom::Point3d.new(
            center[0].to_f.mm,
            center[1].to_f.mm,
            center[2].to_f.mm
          )

          normal_vector = Geom::Vector3d.new(
            normal[0].to_f,
            normal[1].to_f,
            normal[2].to_f
          )

          unless normal_vector.valid? && normal_vector.length > 0
            raise MCPforSketchUp::Core::StructuredError.new(
              code: -32602,
              message: "normal must be a non-zero vector",
              data: { "field" => "normal" }
            )
          end

          edges = group.entities.add_circle(
            center_point,
            normal_vector,
            radius.to_f.mm,
            segments
          )

          group.name = name.to_s if name && !name.to_s.empty?

          hierarchy = Helpers::Paths.finish_creation(group, context) if context
          model.commit_operation

          bbox = group.bounds

          result = {
            "id" => group.entityID,
            "name" => group.name,
            "type" => "circle",
            "center_mm" => center,
            "radius_mm" => radius.to_f,
            "normal" => normal,
            "segments" => segments,
            "edge_count" => edges.length,
            "bbox_mm" => {
              "min" => [
                bbox.min.x.to_mm,
                bbox.min.y.to_mm,
                bbox.min.z.to_mm
              ],
              "max" => [
                bbox.max.x.to_mm,
                bbox.max.y.to_mm,
                bbox.max.z.to_mm
              ]
            }
          }
          hierarchy ? result.merge(hierarchy) : result
        rescue StandardError
          model.abort_operation
          raise
        end
      end

      # Generate a smooth controlled spline.
      #
      # For open curves, endpoint tangents are clamped.
      # Interior tangents are limited to prevent excessive overshoot.
      def self.controlled_spline_points(points, closed, samples)
        if closed
          build_closed_spline(points, samples)
        else
          build_open_spline(points, samples)
        end
      end

      # Open spline.
      def self.build_open_spline(points, samples)
        tangents = calculate_open_tangents(points)
        result = []

        (0...(points.length - 1)).each do |i|
          p0 = points[i]
          p1 = points[i + 1]
          m0 = tangents[i]
          m1 = tangents[i + 1]

          samples.times do |step|
            t = step.to_f / samples

            result << hermite_point(
              p0,
              p1,
              m0,
              m1,
              t
            )
          end
        end

        result << points.last
        result
      end

      # Closed spline.
      def self.build_closed_spline(points, samples)
        count = points.length
        tangents = calculate_closed_tangents(points)
        result = []

        count.times do |i|
          p0 = points[i]
          p1 = points[(i + 1) % count]
          m0 = tangents[i]
          m1 = tangents[(i + 1) % count]

          samples.times do |step|
            t = step.to_f / samples

            result << hermite_point(
              p0,
              p1,
              m0,
              m1,
              t
            )
          end
        end

        result << result.first
        result
      end

      # Calculate tangents for an open curve.
      #
      # Interior tangents use neighboring points.
      # Each tangent component is limited against the local
      # segment direction to reduce overshoot.
      def self.calculate_open_tangents(points)
        tangents = Array.new(points.length)

        # First endpoint.
        tangents[0] = vector_between(
          points[0],
          points[1]
        )

        # Interior points.
        (1...(points.length - 1)).each do |i|
          previous = points[i - 1]
          current = points[i]
          following = points[i + 1]

          incoming = vector_between(previous, current)
          outgoing = vector_between(current, following)

          tangent = Geom::Vector3d.new(
            (incoming.x + outgoing.x) * 0.5,
            (incoming.y + outgoing.y) * 0.5,
            (incoming.z + outgoing.z) * 0.5
          )

          tangents[i] = limit_tangent(
            tangent,
            incoming,
            outgoing
          )
        end

        # Last endpoint.
        tangents[-1] = vector_between(
          points[-2],
          points[-1]
        )

        tangents
      end

      # Calculate tangents for a closed curve.
      def self.calculate_closed_tangents(points)
        count = points.length
        tangents = Array.new(count)

        count.times do |i|
          previous = points[(i - 1) % count]
          current = points[i]
          following = points[(i + 1) % count]

          incoming = vector_between(previous, current)
          outgoing = vector_between(current, following)

          tangent = Geom::Vector3d.new(
            (incoming.x + outgoing.x) * 0.5,
            (incoming.y + outgoing.y) * 0.5,
            (incoming.z + outgoing.z) * 0.5
          )

          tangents[i] = limit_tangent(
            tangent,
            incoming,
            outgoing
          )
        end

        tangents
      end

      # Limit tangent components using the local incoming/outgoing
      # directions. This prevents the spline from producing large
      # excursions outside the intended control-point region.
      def self.limit_tangent(tangent, incoming, outgoing)
        Geom::Vector3d.new(
          limit_component(
            tangent.x,
            incoming.x,
            outgoing.x
          ),
          limit_component(
            tangent.y,
            incoming.y,
            outgoing.y
          ),
          limit_component(
            tangent.z,
            incoming.z,
            outgoing.z
          )
        )
      end

      def self.limit_component(value, incoming, outgoing)
        limits = [
          incoming.abs,
          outgoing.abs
        ].select { |v| v > 0.000001 }

        return 0.0 if limits.empty?

        maximum = limits.min

        if value > maximum
          maximum
        elsif value < -maximum
          -maximum
        else
          value
        end
      end

      # Cubic Hermite interpolation.
      def self.hermite_point(p0, p1, m0, m1, t)
        t2 = t * t
        t3 = t2 * t

        h00 = 2.0 * t3 - 3.0 * t2 + 1.0
        h10 = t3 - 2.0 * t2 + t
        h01 = -2.0 * t3 + 3.0 * t2
        h11 = t3 - t2

        x =
          h00 * p0.x +
          h10 * m0.x +
          h01 * p1.x +
          h11 * m1.x

        y =
          h00 * p0.y +
          h10 * m0.y +
          h01 * p1.y +
          h11 * m1.y

        z =
          h00 * p0.z +
          h10 * m0.z +
          h01 * p1.z +
          h11 * m1.z

        Geom::Point3d.new(x, y, z)
      end

      def self.vector_between(a, b)
        Geom::Vector3d.new(
          b.x - a.x,
          b.y - a.y,
          b.z - a.z
        )
      end

      def self.validate_points!(points)
        unless points.is_a?(Array)
          raise MCPforSketchUp::Core::StructuredError.new(
            code: -32602,
            message: "points must be an array of [x, y, z] coordinates",
            data: { "field" => "points" }
          )
        end

        if points.length < 2
          raise MCPforSketchUp::Core::StructuredError.new(
            code: -32602,
            message: "points must contain at least 2 points",
            data: { "field" => "points" }
          )
        end

        points.each_with_index do |point, index|
          unless point.is_a?(Array) &&
                 point.length == 3 &&
                 point.all? { |value| value.is_a?(Numeric) }
            raise MCPforSketchUp::Core::StructuredError.new(
              code: -32602,
              message: "points[#{index}] must be [x, y, z] numeric coordinates",
              data: { "field" => "points[#{index}]" }
            )
          end
        end
      end

      def self.validate_vector3!(value, field)
        unless value.is_a?(Array) &&
               value.length == 3 &&
               value.all? { |item| item.is_a?(Numeric) }
          raise MCPforSketchUp::Core::StructuredError.new(
            code: -32602,
            message: "#{field} must be [x, y, z] numeric coordinates",
            data: { "field" => field }
          )
        end
      end

      def self.validate_closed!(closed)
        return if closed == true || closed == false

        raise MCPforSketchUp::Core::StructuredError.new(
          code: -32602,
          message: "closed must be a boolean",
          data: { "field" => "closed" }
        )
      end

      def self.validate_samples!(samples)
        return if samples >= 2 && samples <= 100

        raise MCPforSketchUp::Core::StructuredError.new(
          code: -32602,
          message: "samples must be between 2 and 100",
          data: { "field" => "samples" }
        )
      end

      def self.validate_circle_segments!(segments)
        return if segments >= 8 && segments <= 512

        raise MCPforSketchUp::Core::StructuredError.new(
          code: -32602,
          message: "segments must be between 8 and 512",
          data: { "field" => "segments" }
        )
      end
    end
  end
end