# mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch.rb
require "json"

module MCPforSketchUp
  module Handlers
    module Dispatch
      # Returns response Hash (or nil for notifications).
      #
      # Server-loop writes only if non-nil.
      # Notifications (JSON-RPC 2.0 §4.1) carry no `id` and must NOT
      # receive a response.
      def self.handle(request)
        request_id = nil
        is_notification = false
        tool = nil
        params = {}

        begin
          validate_envelope!(request)

          request_id = request["id"]
          is_notification = !request.key?("id")
          method = request["method"]

          response_body =
            case method
            when "tools/call"
              call_params = request["params"]

              unless call_params.is_a?(Hash)
                raise Core::StructuredError.new(
                  -32602,
                  "tools/call requires params object"
                )
              end

              tool = call_params["name"]

              unless tool.is_a?(String) && !tool.empty?
                raise Core::StructuredError.new(
                  -32602,
                  "tools/call requires non-empty 'name' string"
                )
              end

              params = call_params["arguments"] || {}

              unless params.is_a?(Hash)
                raise Core::StructuredError.new(
                  -32602,
                  "tools/call 'arguments' must be an object"
                )
              end

              call_handler(tool, params)

            else
              raise Core::StructuredError.new(
                -32601,
                "method not found: #{method}"
              )
            end

          return nil if is_notification

          build_success_response(response_body, request_id)

        rescue Core::StructuredError => e
          Core::Logger.log_error(tool || "?", e)

          return nil if is_notification

          Core::Errors.build_error_response(
            e.code,
            e.message,
            Core::Errors.exception_to_data(e, tool || "?", params),
            request_id
          )

        rescue StandardError => e
          Core::Logger.log_error(tool || "?", e)

          return nil if is_notification

          Core::Errors.build_error_response(
            -32603,
            e.message,
            Core::Errors.exception_to_data(e, tool || "?", params),
            request_id
          )

        rescue ScriptError, SystemStackError => e
          # Belt-and-braces: SyntaxError/LoadError/SystemStackError are not
          # StandardError. Without this rescue arm, a handler failure could
          # silently leave the client waiting until timeout.
          Core::Logger.log_error(tool || "?", e)

          return nil if is_notification

          Core::Errors.build_error_response(
            -32603,
            "#{e.class}: #{e.message}",
            Core::Errors.exception_to_data(e, tool || "?", params),
            request_id
          )
        end
      end

      def self.validate_envelope!(request)
        unless request.is_a?(Hash)
          raise Core::StructuredError.new(
            -32600,
            "request must be a JSON object"
          )
        end

        unless request["jsonrpc"] == "2.0"
          raise Core::StructuredError.new(
            -32600,
            "jsonrpc must be '2.0'"
          )
        end

        unless request["method"].is_a?(String) && !request["method"].empty?
          raise Core::StructuredError.new(
            -32600,
            "method must be a non-empty string"
          )
        end
      end

      def self.build_success_response(result, request_id)
        {
          "jsonrpc" => "2.0",
          "result"  => wrap_content(result),
          "id"      => request_id
        }
      end

      # Wrap raw handler result into MCP shape:
      # {content: [{type: "text", text: ...}]}
      #
      # `isError: false` is required by the MCP `tools/call` spec.
      #
      # Python `_call` extracts content[0].text and returns it as plain string.
      # Handlers returning Hash -> JSON-encoded text.
      # eval_ruby returning String -> returned as-is.
      def self.wrap_content(result)
        text = result.is_a?(String) ? result : JSON.generate(result)

        {
          "content" => [
            {
              "type" => "text",
              "text" => text
            }
          ],
          "isError" => false
        }
      end

      def self.call_handler(tool, params)
        case tool
        when "create_assembly"
          Handlers::Assemblies.create_assembly(params)

        when "reparent_entities"
          Handlers::Assemblies.reparent_entities(params)

        when "duplicate_component"
          Handlers::Assemblies.duplicate_component(params)

        when "get_camera"
          Handlers::Cameras.get_camera(params)

        when "set_camera"
          Handlers::Cameras.set_camera(params)

        when "save_scene"
          Handlers::Scenes.save_scene(params)

        when "list_scenes"
          Handlers::Scenes.list_scenes(params)

        when "activate_scene"
          Handlers::Scenes.activate_scene(params)

        when "delete_scene"
          Handlers::Scenes.delete_scene(params)

        when "save_model"
          Handlers::Export.save_model(params)

        when "create_component"
          Handlers::Geometry.create_component(params)

        when "create_curve"
          Handlers::BunnuGeometry.create_curve(params)

        when "create_circle"
          Handlers::BunnuGeometry.create_circle(params)

        when "delete_component"
          Handlers::Geometry.delete_component(params)

        when "transform_component"
          Handlers::Geometry.transform_component(params)

        when "set_material"
          Handlers::Materials.set_material(params)

        when "export", "export_scene"
          Handlers::Export.export(params)

        when "boolean_operation"
          Handlers::Operations.boolean_operation(params)

        when "chamfer_edges"
          Handlers::Operations.chamfer_edges(params)

        when "fillet_edges"
          Handlers::Operations.fillet_edges(params)

        when "create_mortise_tenon"
          Handlers::Joints.create_mortise_tenon(params)

        when "create_dovetail"
          Handlers::Joints.create_dovetail(params)

        when "create_finger_joint"
          Handlers::Joints.create_finger_joint(params)

        when "eval_ruby"
          Handlers::Eval.eval_ruby(params)

        when "get_model_info"
          Handlers::Model.get_model_info(params)

        when "list_components"
          Handlers::Model.list_components(params)

        when "get_component_info"
          Handlers::Model.get_component_info(params)

        when "find_components"
          Handlers::Model.find_components(params)

        when "list_layers"
          Handlers::Model.list_layers(params)

        when "create_layer"
          Handlers::Model.create_layer(params)

        when "undo"
          Handlers::Model.undo(params)

        when "get_selection"
          Handlers::Model.get_selection(params)

        when "get_viewport_screenshot"
          Handlers::View.viewport_screenshot(params)

        when "get_version"
          Handlers::System.get_version(params)

        else
          raise Core::StructuredError.new(
            -32601,
            "unknown tool: #{tool}"
          )
        end
      end
    end
  end
end