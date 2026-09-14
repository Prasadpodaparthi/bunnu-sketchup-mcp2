require "minitest/autorun"
require "tmpdir"
require_relative "support/assembly_fakes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/paths"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/assemblies"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/model"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/cameras"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/scenes"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/export"

class TestStructuredAssemblies < Minitest::Test
  P = MCPforSketchUp::Helpers::Paths
  A = MCPforSketchUp::Handlers::Assemblies
  S = MCPforSketchUp::Handlers::Scenes
  C = MCPforSketchUp::Handlers::Cameras
  M = MCPforSketchUp::Handlers::Model
  X = MCPforSketchUp::Handlers::Export
  Error = MCPforSketchUp::Core::StructuredError

  def setup
    @original = {}
    {Geom: AssemblyFakes::Geom, Sketchup: AssemblyFakes::Sketchup}.each do |name,value|
      @original[name] = Object.const_get(name) if Object.const_defined?(name)
      Object.send(:remove_const,name) if Object.const_defined?(name)
      Object.const_set(name,value)
    end
    @model=Sketchup::Model.new;Sketchup.active_model=@model
    require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/view" unless defined?(MCPforSketchUp::Handlers::View)
    @old_active = MCPforSketchUp::Helpers::Entities.method(:active_model!)
    model=@model;MCPforSketchUp::Helpers::Entities.define_singleton_method(:active_model!) { model }
    @flags={}
    %w[PAGE_USE_CAMERA PAGE_USE_HIDDEN_OBJECTS PAGE_USE_LAYER_VISIBILITY PAGE_USE_RENDERING_OPTIONS].each_with_index do |name,i|
      @flags[name]=Object.const_get(name) if Object.const_defined?(name)
      Object.const_set(name,1 << i) unless Object.const_defined?(name)
    end
    @unrelated=part("Existing building",@model.entities,[900,0,0])
    @parent=part("New furniture",@model.entities,[10,0,0])
    @child=part("Door",@parent.entities,[2,0,0])
    @before=P.matrix_mm(@unrelated.transformation)
  end

  def teardown
    assert_equal @before,P.matrix_mm(@unrelated.transformation),"unrelated entity moved"
    assert @unrelated.valid?,"unrelated entity erased"
    MCPforSketchUp::Helpers::Entities.define_singleton_method(:active_model!,@old_active)
    [:Geom,:Sketchup].each do |name|
      Object.send(:remove_const,name)
      Object.const_set(name,@original[name]) if @original[name]
    end
    %w[PAGE_USE_CAMERA PAGE_USE_HIDDEN_OBJECTS PAGE_USE_LAYER_VISIBILITY PAGE_USE_RENDERING_OPTIONS].each do |name|
      Object.send(:remove_const,name) unless @flags.key?(name)
    end
  end

  def part(name,entities,translation=[0,0,0])
    e=entities.add_group;e.name=name
    e.definition.box=Geom::BoundingBox.new.add(Geom::Point3d.new(0,0,0),Geom::Point3d.new(1,2,3))
    e.transformation=Geom::Transformation.translation(translation);e
  end
  def child_path;P.key([@parent,@child]);end
  def parent_path;P.key([@parent]);end
  def transform(args)
    A.transform_component({"instance_path"=>child_path}.merge(args))
  end
  def assert_point(expected,actual)
    expected.zip(actual).each { |a,b| assert_in_delta a,b,1e-7 }
  end

  def test_resolves_persistent_path_not_legacy_id
    assert_equal [@parent,@child],P.resolve(child_path)
    assert_raises(Error) { P.resolve(@child.entityID.to_s) }
    assert_raises(Error) { P.resolve("#{@parent.persistent_id}.999999") }
  end
  def test_root_explicitly_ignores_ui_active_context
    @model.active_path=[@unrelated]
    assert_equal @model.entities,P.creation_context({"parent_path"=>""})[:entities]
    assert_equal @parent.definition.entities,P.creation_context({"parent_path"=>parent_path})[:entities]
  end
  def test_hierarchy_returns_parent_path_and_world_bounds
    data=P.describe(P.resolve(child_path))
    assert_equal parent_path,data["parent_path"]
    assert_point [304.8,0,0],data["bbox_mm"]["min"]
    assert_in_delta 50.8,data["transform_local_mm"][12]
    assert_in_delta 304.8,data["transform_world_mm"][12]
  end
  def test_shared_occurrences_have_distinct_paths_and_bounds
    copy=@model.entities.add_instance(@parent.definition,Geom::Transformation.translation([20,0,0]))
    other=P.key([copy,@child])
    assert_equal @child,P.resolve(other).last
    refute_equal P.describe(P.resolve(child_path))["bbox_mm"],P.describe(P.resolve(other))["bbox_mm"]
    assert_raises(Error) { transform("translation_mm"=>[10,0,0]) }
    assert_empty @model.operations
  end
  def test_legacy_id_in_new_transform_rejects_ambiguous_occurrence
    @model.entities.add_instance(@parent.definition,Geom::Transformation.new)
    assert_raises(Error) { A.transform_component({"id"=>@child.entityID,"translation_mm"=>[10,0,0]}) }
  end
  def test_leaf_instance_can_move_without_editing_shared_definition
    @model.entities.add_instance(@child.definition,Geom::Transformation.new)
    transform("translation_mm"=>[25.4,0,0])
    assert_in_delta 3,@child.transformation.to_a[12]
  end
  def test_locked_ancestor_is_rejected_before_operation
    @parent.locked=true
    assert_raises(Error) { transform("position"=>[0,0,0]) }
    assert_empty @model.operations
  end
  def test_world_position_under_rotated_parent
    @parent.transformation=Geom::Transformation.rotation(Geom::Point3d.new(0,0,0),Geom::Vector3d.new(0,0,1),Math::PI/2)
    data=transform("coordinate_space"=>"world","position"=>[254,508,0])
    assert_point [254,508,0],data["bbox_mm"]["min"]
  end
  def test_local_translation_follows_entity_axes
    @child.transformation=Geom::Transformation.rotation(Geom::Point3d.new(0,0,0),Geom::Vector3d.new(0,0,1),Math::PI/2)
    transform("coordinate_space"=>"local","translation_mm"=>[25.4,0,0])
    assert_point [0,1,0],@child.transformation.to_a[12,3]
  end
  def test_hinge_rotation_keeps_pivot_fixed
    pivot=Geom::Point3d.new(2,0,0)
    result=transform("axis"=>[0,0,1],"angle_degrees"=>90,"pivot_mm"=>[50.8,0,0])
    assert_point pivot.to_a,(@child.transformation * Geom::Point3d.new(0,0,0)).to_a
    assert_equal child_path,result["instance_path"]
  end
  def test_absolute_matrix_roundtrip_is_idempotent
    original=P.matrix_mm(P.world([@parent,@child]))
    transform("translation_mm"=>[100,0,0])
    2.times { transform("coordinate_space"=>"world","matrix_mm"=>original) }
    assert_point original,P.matrix_mm(P.world([@parent,@child]))
  end
  def test_rejects_singular_nonfinite_and_conflicting_transforms
    a=Geom::Transformation.new.to_a;a[0]=0
    assert_raises(Error) { transform("matrix_mm"=>a) }
    a[0]=Float::NAN
    assert_raises(Error) { transform("matrix_mm"=>a) }
    assert_raises(Error) { transform("matrix_mm"=>Geom::Transformation.new.to_a,"position"=>[0,0,0]) }
    assert_raises(Error) { transform("axis"=>[0,0,0],"angle_degrees"=>30) }
    assert_empty @model.operations
  end
  def test_create_assembly_keeps_world_positions_and_group_type
    old=P.describe(P.resolve(child_path))["bbox_mm"]
    data=A.create_assembly({"name"=>"Module","member_paths"=>[child_path],"parent_path"=>""})
    entity=data["members"][0]["entity"]
    assert_equal old,entity["bbox_mm"]
    assert_equal "group",entity["type"]
    assert_equal "Module",data["assembly"]["name"]
    refute @child.valid?
    assert_equal [:commit],@model.operations.last
  end
  def test_create_true_component
    data=A.create_assembly({"name"=>"Module","kind"=>"component","member_paths"=>[child_path]})
    assert_equal "component",data["assembly"]["type"]
  end
  def test_reparent_under_rotated_scaled_parent_keeps_world_matrix
    dest=part("Target",@model.entities)
    dest.transformation=Geom::Transformation.scaling(Geom::Point3d.new(0,0,0),2,3,1) * Geom::Transformation.rotation(Geom::Point3d.new(0,0,0),Geom::Vector3d.new(0,0,1),0.3)
    before=P.matrix_mm(P.world(P.resolve(child_path)))
    data=A.reparent_entities({"entity_paths"=>[child_path],"parent_path"=>P.key([dest])})
    assert_point before,data["entities"][0]["entity"]["transform_world_mm"]
  end
  def test_reparent_rejects_self_descendant_and_overlapping_selection
    assert_raises(Error) { A.reparent_entities({"entity_paths"=>[parent_path],"parent_path"=>child_path}) }
    assert_raises(Error) { A.create_assembly({"name"=>"A","member_paths"=>[parent_path,child_path]}) }
    assert_empty @model.operations
  end
  def test_shared_destination_rejected
    @model.entities.add_instance(@parent.definition,Geom::Transformation.new)
    assert_raises(Error) { P.creation_context({"parent_path"=>parent_path}) }
    assert_empty @model.operations
  end
  def test_creation_world_coordinates_compensate_parent_transform
    context=P.creation_context({"parent_path"=>parent_path,"coordinate_space"=>"world"})
    e=part("New",context[:entities],[20,0,0])
    data=P.finish_creation(e,context)
    assert_point [508,0,0],data["bbox_mm"]["min"]
  end
  def test_hierarchy_query_is_scoped
    data=M.list_components({"parent_path"=>parent_path,"include_hierarchy"=>true})
    assert_equal [child_path],data["components"].map { |e| e["instance_path"] }
  end
  def test_camera_validation_and_readback
    camera={"eye_mm"=>[0,-2540,0],"target_mm"=>[0,0,0],"up"=>[0,0,1],"projection"=>"parallel","height_mm"=>800}
    data=C.set_camera({"camera"=>camera})
    assert_in_delta 800,data["height_mm"]
    assert_equal "parallel",data["projection"]
    assert_raises(Error) { C.build(camera.merge("up"=>[0,1,0])) }
    assert_raises(Error) { C.build(camera.merge("eye_mm"=>[0,0,0])) }
  end
  def test_scene_create_and_rename_preserve_saved_camera
    result=S.save_scene({"name"=>"Front"})
    page=S.find(result["scene_id"])
    before=C.describe(page.camera)
    @model.active_view.camera=Sketchup::Camera.new(Geom::Point3d.new(1,2,3),Geom::Point3d.new(0,0,0),Geom::Vector3d.new(0,0,1))
    S.save_scene({"scene_id"=>page.persistent_id,"name"=>"Renamed"})
    assert_equal before,C.describe(page.camera)
    assert_equal "Renamed",page.name
    assert_equal 1,page.updates.length
  end
  def test_scene_pose_roundtrip_and_stale_path_rejection
    result=S.save_scene({"name"=>"Closed","pose_paths"=>[child_path]})
    old=@child.transformation.to_a
    transform("translation_mm"=>[100,0,0])
    S.activate_scene({"scene_id"=>result["scene_id"]})
    assert_point old,@child.transformation.to_a
    @child.erase!
    assert_raises(Error) { S.activate_scene({"scene_id"=>result["scene_id"]}) }
  end
  def test_scene_visibility_does_not_change_geometry_when_saved
    S.save_scene({"name"=>"Internal","visibility"=>[{"instance_path"=>child_path,"visible"=>false}]})
    refute @child.hidden?
    assert @child.valid?
  end
  def test_scene_delete_retains_entities_and_other_scenes
    a=S.save_scene({"name"=>"One"});b=S.save_scene({"name"=>"Two"})
    S.delete_scene({"scene_id"=>a["scene_id"]})
    assert_equal [b["scene_id"]],S.list_scenes({})["scenes"].map { |s| s["scene_id"] }
    assert @child.valid?
  end
  def test_save_model_requires_explicit_absolute_path_and_expected_document
    assert_raises(Error) { X.save_model({"path"=>"relative.skp"}) }
    Dir.mktmpdir do |dir|
      path=File.join(dir,"Master.skp")
      assert_raises(Error) { X.save_model({"path"=>path,"expected_current_path"=>"wrong.skp"}) }
      assert_empty @model.saved_paths
      result=X.save_model({"path"=>path,"expected_current_path"=>@model.path})
      assert_equal path,result["path"]
      assert_equal [path],@model.saved_paths
      refute File.exist?(path),"fake model must not write actual .skp files"
    end
  end
  def test_save_model_reports_failure
    @model.save_result=false
    Dir.mktmpdir do |dir|
      assert_raises(Error) { X.save_model({"path"=>File.join(dir,"Master.skp")}) }
    end
  end
  def test_operation_aborts_on_error
    assert_raises(RuntimeError) { P.operation("Failure") { raise "injected failure" } }
    assert_equal [:abort],@model.operations.last
  end

  def test_duplicate_unique_isolates_nested_definitions
    result=A.duplicate_component({"instance_path"=>parent_path,"name"=>"Independent copy"})
    copy=P.resolve(result["instance_path"]).last
    refute_equal @parent.definition,copy.definition
    refute_equal @child.definition,copy.definition.entities.first.definition
    assert @parent.valid?
  end

  def test_camera_frames_only_requested_assembly_in_portrait_view
    @model.active_view.vpwidth=300;@model.active_view.vpheight=900
    result=C.set_camera({"view_preset"=>"front","frame_paths"=>[child_path],"projection"=>"parallel"})
    assert_equal "parallel",result["projection"]
    assert_point P.bounds(P.resolve(child_path)).center.to_a.map { |n| n*25.4 },result["target_mm"]
    assert_operator result["height_mm"],:>,3*25.4
  end

  def test_screenshot_failure_restores_camera_and_aborts
    old=C.describe
    handler=MCPforSketchUp::Handlers::View
    handler.stub(:viewport_screenshot, ->(_p) { raise "write_image failed" }) do
      assert_raises(RuntimeError) do
        C.screenshot({"frame_paths"=>[child_path],"view_preset"=>"front","projection"=>"parallel"})
      end
    end
    assert_equal old,C.describe
    assert_equal [:abort],@model.operations.last
  end

  def test_scene_screenshot_restores_poses_visibility_and_camera
    data=S.save_scene({"name"=>"Closed","pose_paths"=>[child_path],"visibility"=>[{"instance_path"=>child_path,"visible"=>false}]})
    transform("translation_mm"=>[100,0,0])
    before=@child.transformation.to_a;old=C.describe
    handler=MCPforSketchUp::Handlers::View
    handler.stub(:viewport_screenshot, ->(p) {
      refute p.key?("scene_id"),"delegation must not recurse into structured capture"
      assert @child.hidden?
      refute_equal before,@child.transformation.to_a
      {"png_base64"=>"", "width"=>800,"height"=>600}
    }) do
      result=C.screenshot({"scene_id"=>data["scene_id"]})
      assert_equal data["scene_id"],result["scene_id"]
    end
    assert_equal before,@child.transformation.to_a
    refute @child.hidden?
    assert_equal old,C.describe
    assert_equal [:abort],@model.operations.last
  end

  def test_master_overwrite_requires_explicit_flag
    Dir.mktmpdir do |dir|
      path=File.join(dir,"Master.skp")
      # A plain marker file, not a SketchUp model.
      File.write(path,"test marker")
      assert_raises(Error) { X.save_model({"path"=>path}) }
      assert_empty @model.saved_paths
      X.save_model({"path"=>path,"overwrite"=>true})
      assert_equal "test marker",File.read(path)
    end
  end

  def test_pose_observer_does_not_apply_on_attach_or_property_update
    data=S.save_scene({"name"=>"Closed","pose_paths"=>[child_path]})
    @model.pages.selected_page=S.find(data["scene_id"])
    observer=S::PoseObserver.new(@model)
    transform("translation_mm"=>[100,0,0])
    before=@child.transformation.to_a
    observer.onContentsModified(@model.pages)
    assert_equal before,@child.transformation.to_a
  end

  def test_native_scene_selection_restores_only_registered_pose_targets
    data=S.save_scene({"name"=>"Closed","pose_paths"=>[child_path]})
    closed=@child.transformation.to_a
    observer=S::PoseObserver.new(@model)
    transform("translation_mm"=>[100,0,0])
    @model.pages.selected_page=S.find(data["scene_id"])
    original_ui=Object.const_get(:UI) if Object.const_defined?(:UI)
    Object.send(:remove_const,:UI) if original_ui
    fake_ui=Module.new
    fake_ui.define_singleton_method(:start_timer) { |_n,_repeat,&block| block.call }
    Object.const_set(:UI,fake_ui)
    observer.onContentsModified(@model.pages)
    assert_point closed,@child.transformation.to_a
  ensure
    Object.send(:remove_const,:UI) if defined?(fake_ui) && fake_ui
    Object.const_set(:UI,original_ui) if original_ui
  end

  def test_concise_hierarchy_still_identifies_occurrence
    data=M.list_components({"parent_path"=>parent_path,"response_format"=>"concise"})
    assert_equal child_path,data["components"][0]["instance_path"]
    refute data["components"][0].key?("bbox_mm")
  end

  def test_mismatched_legacy_id_and_path_are_rejected
    assert_raises(Error) { P.target({"instance_path"=>child_path,"id"=>@unrelated.entityID}) }
    assert_empty @model.operations
  end

  def test_reparent_same_parent_is_noop_and_local_mode_retains_local_matrix
    result=A.reparent_entities({"entity_paths"=>[child_path],"parent_path"=>parent_path})
    assert_equal child_path,result["entities"][0]["entity"]["instance_path"]
    old=@child.transformation.to_a
    result=A.reparent_entities({"entity_paths"=>[child_path],"parent_path"=>"","preserve_world_transform"=>false})
    moved=P.resolve(result["entities"][0]["entity"]["instance_path"]).last
    assert_point old,moved.transformation.to_a
  end

  def test_nonrestoring_capture_commits_and_returns_effective_camera
    handler=MCPforSketchUp::Handlers::View
    handler.stub(:viewport_screenshot, ->(_p) { {"width"=>800,"height"=>600} }) do
      result=C.screenshot({"frame_paths"=>[child_path],"projection"=>"parallel","restore_view"=>false})
      assert_equal "parallel",result["camera"]["projection"]
    end
    assert_equal [:commit],@model.operations.last
    refute @model.active_view.camera.perspective?
  end
end
