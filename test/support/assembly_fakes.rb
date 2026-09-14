# In-memory SketchUp API doubles. Matrix arithmetic is real stdlib Matrix math;
# these tests neither load SketchUp nor create/write an actual .skp document.
require "matrix"

module AssemblyFakes
  module Geom
    class Vector3d
      attr_accessor :x, :y, :z
      def initialize(*args); @x, @y, @z = (args.length == 1 ? args[0].to_a : args).map(&:to_f); end
      def to_a; [x, y, z]; end
      def length; Math.sqrt(to_a.sum { |v| v*v }); end
      def length=(n); f = n / length; @x *= f; @y *= f; @z *= f; end
      def cross(o); Vector3d.new(y*o.z-z*o.y, z*o.x-x*o.z, x*o.y-y*o.x); end
      def +(o); self.class.new(x+o.x, y+o.y, z+o.z); end
      def -(o); Vector3d.new(x-o.x, y-o.y, z-o.z); end
    end
    class Point3d < Vector3d; end
    class Transformation
      attr_reader :m
      def initialize(a = nil)
        @m = a ? Matrix.columns(a.each_slice(4).to_a) : Matrix.identity(4)
      end
      def to_a; m.transpose.to_a.flatten; end
      def *(other)
        if other.is_a?(Transformation)
          Transformation.new((m * other.m).transpose.to_a.flatten)
        else
          v = m * Vector[*other.to_a, other.is_a?(Point3d) ? 1 : 0]
          other.class.new(*v.to_a.first(3))
        end
      end
      def inverse; Transformation.new(m.inverse.transpose.to_a.flatten); end
      def self.translation(v)
        a = new.to_a; a[12, 3] = v.to_a; new(a)
      end
      def self.scaling(p, *s)
        a = new.to_a; [0, 5, 10].each_with_index { |i, j| a[i] = s[j] }
        translation(p) * new(a) * translation(p.to_a.map { |v| -v })
      end
      def self.rotation(p, axis, angle)
        v = axis.to_a.map { |n| n / axis.length }; x, y, z = v
        c = Math.cos(angle); s = Math.sin(angle); k = 1-c
        rows = [[c+x*x*k, x*y*k-z*s, x*z*k+y*s, 0],
                [y*x*k+z*s, c+y*y*k, y*z*k-x*s, 0],
                [z*x*k-y*s, z*y*k+x*s, c+z*z*k, 0], [0,0,0,1]]
        translation(p) * new(Matrix.rows(rows).transpose.to_a.flatten) * translation(p.to_a.map { |n| -n })
      end
    end
    class BoundingBox
      attr_reader :min, :max
      def initialize
        @min = Point3d.new(Float::INFINITY, Float::INFINITY, Float::INFINITY)
        @max = Point3d.new(-Float::INFINITY, -Float::INFINITY, -Float::INFINITY)
        @empty = true
      end
      def add(*points)
        points.each do |p|
          @min = Point3d.new(*min.to_a.zip(p.to_a).map(&:min))
          @max = Point3d.new(*max.to_a.zip(p.to_a).map(&:max))
          @empty = false
        end
        self
      end
      def empty?; @empty; end
      def valid?; !empty?; end
      def corner(i); Point3d.new((i & 1) == 0 ? min.x : max.x, (i & 2) == 0 ? min.y : max.y, (i & 4) == 0 ? min.z : max.z); end
      def center; Point3d.new(*min.to_a.zip(max.to_a).map { |a,b| (a+b)/2 }); end
      def diagonal; (max-min).length; end
    end
  end

  module Sketchup
    class << self
      attr_accessor :active_model
    end
    class Definition
      attr_accessor :entities, :box
      attr_reader :instances, :persistent_id
      def initialize(model)
        @model = model; @instances = []; @entities = Entities.new(model)
        @persistent_id = model.next_id
      end
      def bounds
        bb = Geom::BoundingBox.new
        bb.add(box.min, box.max) if box
        entities.each { |e| b = e.bounds; bb.add(b.min, b.max) unless b.empty? }
        bb
      end
    end
    class Group
      attr_accessor :name, :transformation, :layer, :material, :hidden, :casts_shadows, :receives_shadows, :locked
      attr_reader :definition, :persistent_id, :parent
      def initialize(model, parent, definition = nil)
        @model = model; @parent = parent; @definition = definition || Definition.new(model)
        @definition.instances << self; @persistent_id = model.next_id
        @name = ""; @transformation = Geom::Transformation.new
        @layer = model.layers[0]; @hidden = false; @locked = false; @valid = true
        @attributes = {}
      end
      def entityID; persistent_id + 10000; end
      def entities; definition.entities; end
      def locked?; @locked; end
      def hidden?; @hidden; end
      def casts_shadows?; @casts_shadows; end
      def receives_shadows?; @receives_shadows; end
      def attribute_dictionaries; nil; end
      def set_attribute(d,k,v); (@attributes[d] ||= {})[k] = v; end
      def valid?; @valid; end
      def bounds
        bb = Geom::BoundingBox.new; local = definition.bounds
        8.times { |i| bb.add(transformation * local.corner(i)) } unless local.empty?
        bb
      end
      def erase!; @valid = false; parent.delete(self); definition.instances.delete(self); end
      def make_unique
        old = definition
        old.instances.delete(self)
        @definition = Definition.new(@model); @definition.box = old.box; @definition.instances << self
        old.entities.each do |e|
          copy = @definition.entities.add_instance(e.definition, e.transformation)
          copy.name = e.name
        end
        self
      end
      def to_component
        result = parent.add_instance(definition, transformation)
        erase!
        result
      end
    end
    # ComponentInstance deliberately does not subclass Group (as in SketchUp).
    class ComponentInstance; end
    # Delegate storage while retaining distinct Group/ComponentInstance types.
    Group.instance_methods(false).each do |name|
      # Unbound methods from a class cannot bind to unrelated classes. Delegate
      # through a group-shaped storage object while presenting component type.
      next if name == :to_component
      ComponentInstance.define_method(name) { |*a, &b| @storage.public_send(name, *a, &b) }
    end
    ComponentInstance.class_eval do
      def initialize(model, parent, definition)
        @storage = Group.new(model, parent, definition)
        definition.instances.delete(@storage); definition.instances << self
      end
      def erase!
        @storage.erase!
        parent.delete(self); definition.instances.delete(self)
      end
      def make_unique
        old = definition
        old.instances.delete(self)
        @storage.make_unique
        definition.instances.delete(@storage)
        definition.instances << self
        self
      end
      def explode
        # The only explode in production is a temporary definition instance
        # inside a new Group. Preserve nested parts; carry raw box geometry.
        owner = parent.owner
        owner.box = definition.box if owner
        definition.entities.each do |e|
          copy = parent.add_instance(e.definition, transformation * e.transformation)
          copy.name = e.name
        end
        erase!
        parent.to_a
      end
    end
    class Entities < Array
      attr_accessor :owner
      def initialize(model); @model = model; super(); end
      def add_group
        e = Group.new(@model,self); e.definition.entities.owner = e.definition; self << e; e
      end
      def add_instance(d,t)
        e = ComponentInstance.new(@model,self,d); e.transformation = t; self << e; e
      end
    end
    class Layer
      attr_accessor :visible, :name
      def initialize; @visible = true; @name = "Untagged"; end
      def visible?; visible; end
      def page_behavior; 0; end
    end
    class Camera
      attr_accessor :eye, :target, :up, :perspective, :height, :fov, :aspect_ratio, :image_width
      def initialize(eye, target, up, perspective = true)
        set(eye,target,up); @perspective = perspective; @height = 50; @fov = 35; @aspect_ratio = 0; @image_width = 0
      end
      def set(e,t,u); @eye=e; @target=t; @up=Geom::Vector3d.new(u.x,u.y,u.z); end
      def perspective?; @perspective; end
      def is_2d?; false; end
      def fov_is_height?; true; end
    end
    class View
      attr_accessor :camera, :vpwidth, :vpheight
      def initialize
        @camera = Camera.new(Geom::Point3d.new(0,-100,0),Geom::Point3d.new(0,0,0),Geom::Vector3d.new(0,0,1))
        @vpwidth = 800; @vpheight = 600
      end
      def refresh; end
    end
    class Page
      attr_accessor :name, :description, :transition_time, :include_in_animation, :camera
      attr_reader :persistent_id, :rendering_options, :updates
      %w[camera hidden_objects hidden_layers rendering_options axes section_planes shadow_info style environment].each do |flag|
        attr_writer "use_#{flag}"
        define_method("use_#{flag}?") { instance_variable_get("@use_#{flag}") || false }
      end
      def initialize(model,name)
        @model=model; @name=name; @persistent_id=model.next_id; @description=""; @transition_time=1
        @camera=model.active_view.camera; @rendering_options=model.rendering_options.dup
        @attributes={}; @visibility={}; @updates=[]
      end
      def include_in_animation?; @include_in_animation; end
      def update(flags); @updates << flags; true; end
      def layers; []; end
      def layer_folders; []; end
      def get_attribute(d,k,default=nil); @attributes.fetch([d,k],default); end
      def set_attribute(d,k,v); @attributes[[d,k]]=v; end
      def set_drawingelement_visibility(e,v); @visibility[e]=v; end
      def get_drawingelement_visibility(e); @visibility.fetch(e,!e.hidden?); end
    end
    class Pages < Array
      attr_accessor :selected_page
      def initialize(model); @model=model; super(); end
      def add(name); p=Page.new(@model,name);self << p;p;end
      def erase(p);delete(p);end
    end
    class Model
      attr_accessor :path, :save_result, :active_path
      attr_reader :entities, :layers, :active_view, :rendering_options, :pages, :operations, :saved_paths
      def initialize
        @counter=0;@entities=Entities.new(self);@layers=[Layer.new];@active_view=View.new
        @rendering_options={"RenderMode" => 2};@pages=Pages.new(self);@operations=[];@saved_paths=[]
        @path="C:/existing.skp";@save_result=true
      end
      def next_id;@counter+=1;end
      def start_operation(name,*);@operations << [:start,name];end
      def commit_operation;@operations << [:commit];end
      def abort_operation;@operations << [:abort];end
      def save(path);@saved_paths << path;@path=path if save_result;save_result;end
    end
  end
end
