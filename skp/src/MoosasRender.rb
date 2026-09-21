# Ver.0.6.1
class MoosasRender
    
    @entity_materials = nil unless instance_variable_defined?(:@entity_materials)
    @visulized = false unless instance_variable_defined?(:@visulized)
    # Session-only debug switch: no UI/settings binding, disabled on fresh start.
    @debug_face_ids = false unless instance_variable_defined?(:@debug_face_ids)
    FACE_UID_LABEL_DICTIONARY = 'moosas_visualization'
    FACE_UID_LABEL_KEY = 'face_uid_labels'
    $define_materials ||= {}
    $backup_materials ||= {}

    def self.debug_face_ids?
        @debug_face_ids == true
    end

    # Backend only. Explicitly called from Ruby/Agent Bridge when debugging.
    def self.set_debug_face_ids(enabled)
        raise ArgumentError, 'Expected true or false' unless enabled == true || enabled == false
        model = Sketchup.active_model
        previous = @debug_face_ids
        model.start_operation('Moosas: debug face IDs', true)
        begin
            @debug_face_ids = enabled
            enabled ? add_face_uid_labels(model) : remove_face_uid_labels(model)
            model.commit_operation
        rescue
            @debug_face_ids = previous
            model.abort_operation
            raise
        end
        @debug_face_ids
    end

    def self.update_define_materials(face,cat)
    # """
    # Function
    # --------
    # Updates the defined materials mapping for a given face with the specified category.
    # 
    # Parameters
    # ----------
    # face : Sketchup::Face
    # The face entity whose persistent ID will be used as the key in the material mapping.
    # cat : Integer or String
    # The category identifier to associate with the face. If provided as a string,
    # it will be converted to an integer.
    # 
    # Returns
    # -------
    # nil
    # This method does not return a value. It modifies the global `$define_materials` hash
    # by setting the entry keyed by `face.persistent_id` to the integer value of `cat`,
    # but only if `cat` exists as a key in the `@entity_materials` hash.
    # 
    # Notes
    # -----
    # - The method ensures `@entity_materials` is loaded by calling `load_entity_materials`
    # if it is not already initialized.
    # - The update only occurs if the category (after type conversion) exists as a key
    # in the `@entity_materials` hash.
    # """
        if @entity_materials == nil
            self.load_entity_materials
        end
        if cat.is_a?(String)
            cat = cat.to_i
        end
        if @entity_materials.has_key?(cat)
            $define_materials[face.persistent_id] = cat
        end
    end

    def self.mark_face(cat)
    # Function
    # ----------
    # Marks faces in the active SketchUp model selection by applying defined materials based on category mapping.
    # Applies a material with prefix 'moosas_' to both front and back of each face, backed up original materials if not already saved.
    # 
    # Parameters
    # ----------
    # cat : Object
    # A category identifier used to determine which materials to apply to the selected faces.
    # Expected to be used as a key in material definition lookups.
    # 
    # Returns
    # -------
    # nil
    # This method does not return a value. It performs side effects by modifying face materials
    # and updating global state ($backup_materials, $define_materials).
        entities = Sketchup.active_model.selection
        self.traverse_faces(entities) do |face,path|
            self.update_define_materials(face,cat)
            if $define_materials.has_key?(face.persistent_id)
                if $backup_materials[face.persistent_id]==nil
                    $backup_materials[face.persistent_id]=[face.material,face.back_material]
                end
                mat = "moosas_" + @entity_materials[$define_materials[face.persistent_id]]
                face.material = mat
                face.back_material = mat
            end
        end
    end

    def self.visualize_repeat(model)
    # """
    # Function
    # --------
    # Toggle visualization state for a given model entity type. If already visualized,
    # it attempts to disable the visualization; otherwise, it attempts to enable it.
    # 
    # Parameters
    # ----------
    # model : object
    # The model entity type to be visualized or whose visualization is to be disabled.
    # Expected to be a valid entity type supported by the visualization system.
    # 
    # Returns
    # -------
    # None
    # This method does not return a value. It performs side effects by modifying
    # the internal visualization state and attempting to visualize or hide the model.
    # """
        if @visulized
            begin
                self.disable_visualize_entity_type(model)
            rescue StandardError => e
                p "Error disable visualize"
                @visulized = false
            end
            
        else
            begin
                self.visualize_entity_type(model)  
            rescue StandardError => e
                p "Error visualize"
                @visulized = true
            end
            
        end
    end

    def self.visualize_entity_type(model)
        return if @visulized
    # Function:
    # Visualizes the type of each face in the model by applying specific materials based on predefined entity types.
    # This method temporarily changes the material of faces to reflect their semantic classification (e.g., shading, surrounding),
    # stores original materials for later restoration, and marks the model as visualized.
    # 
    # Parameters:
    # model : Sketchup::Model
    # The SketchUp model object whose entities (specifically faces) will be traversed and visually marked according to their entity type.
    # Although passed as a parameter, the method internally uses Sketchup.active_model instead of this argument.
    # 
    # Returns:
    # None
    # This method does not return a value. It modifies the model's face materials and updates internal state (@backup_materials, @visulized).

        self.load_entity_materials

        Sketchup.active_model.start_operation("标记面的类型", true)

        model = Sketchup.active_model

        begin
        self.traverse_faces(model.entities) do |face,path|
            if $define_materials.has_key?(face.persistent_id)
                if $backup_materials[face.persistent_id]==nil
                    $backup_materials[face.persistent_id]=[face.material,face.back_material]
                end
                mat = "moosas_" + @entity_materials[$define_materials[face.persistent_id]]
                material = model.materials[mat]
                if defined?(MoosasModelPage)
                    MoosasModelPage.assign(face, :material, material)
                    MoosasModelPage.assign(face, :back_material, material)
                else
                    face.material = mat
                    face.back_material = mat
                end
            end
        end

        self.add_face_uid_labels(model)

        # moosas_faces = MMR.all_recognized_faces
        #
        # moosas_faces.each do |mf|
        #     #p "id =#{mf.id}, type = #{mf.type}"
        #     mat = "moosas_" + @entity_materials[mf.type]
        #     face = mf.face
        #     if $backup_materials[face.persistent_id]==nil
        #         $backup_materials[face.persistent_id]=[face.material,face.back_material]
        #     end
        #     face.material = mat
        #     face.back_material = mat
        #     if mf.type == MoosasConstant::ENTITY_SHADING or mf.type == MoosasConstant::ENTITY_SURROUNDING
        #         face.material.alpha=0.5
        #     end
        # end
        #
        # m=Sketchup.active_model
        # entities=m.active_entities

        #for s in model.spaces
        #    entities=s.construct_space_volume(entities)
        #end
        Sketchup.active_model.commit_operation

        #Sketchup.send_action "showRubyPanel:"
        #p "提醒：\r\n进入标签状态后，在任何修改模型操作之前，请点击\"关闭可视化识别结果\"按钮,退到进入标签前的状态，避免模型材质恢复出错!"
        @visulized=true
        MoosasModelPage.record[:visualized] = true if defined?(MoosasModelPage)
        rescue
            model.abort_operation
            raise
        end
    end


    def self.disable_visualize_entity_type(model)
    # Function:
    # Disables the visualization of entity types by restoring face materials to their original values
    # from a backup hash and marking the visualization state as inactive. This method traverses
    # all faces in the model's entities and resets their material and back_material properties
    # if a backup exists for the face.
    # 
    # Parameters:
    # model : Sketchup::Model
    # The SketchUp model whose entities are to be processed. If not provided or nil,
    # defaults to Sketchup.active_model within the method.
    # 
    # Returns:
    # nil
    # Returns nil if @visulized is false at the start of the method.
    # Otherwise, performs material restoration on faces and returns nil after completion.
        model = Sketchup.active_model
        unless @visulized
            self.remove_face_uid_labels(model)
            return
        end
        model.start_operation('Restore face type visualization', true)
        begin
        self.traverse_faces(model.entities) do |face,path|
            if $backup_materials.has_key?(face.persistent_id)
                if defined?(MoosasModelPage)
                    MoosasModelPage.assign(face, :material, $backup_materials[face.persistent_id][0])
                    MoosasModelPage.assign(face, :back_material, $backup_materials[face.persistent_id][1])
                else
                    face.material = $backup_materials[face.persistent_id][0]
                    face.back_material = $backup_materials[face.persistent_id][1]
                end
            end
        end
        self.remove_face_uid_labels(model)
        # moosas_faces = MMR.all_recognized_faces
        #
        #status = Sketchup.active_model.abort_operation  #简单采用撤销操作
        #Sketchup.send_action("editUndo:")
        # moosas_faces = model.get_all_face
        #
        # for i in 0..moosas_faces.length-1
        #     begin
        #         face = moosas_faces[i].face
        #         face.material = $backup_materials[face.persistent_id][0]
        #         face.back_material = $backup_materials[face.persistent_id][1]
        #         # face.material = moosas_faces[i].skp_material[0]
        #         # face.back_material = moosas_faces[i].skp_material[1]
        #     rescue
        #     end
        # end
        @visulized=false
        MoosasModelPage.record[:visualized] = false if defined?(MoosasModelPage)
        $backup_materials.clear
        model.commit_operation
        rescue
            model.abort_operation
            raise
        end
    end

    def self.add_face_uid_labels(model)
    # Add one SketchUp text entity at the centroid of each recognized face.
    # Labels are kept in a marked root group so the toggle can remove them
    # reliably, including after this file has been reloaded.
        self.remove_face_uid_labels(model)
        return unless debug_face_ids?
        labels_group = model.entities.add_group
        labels_group.name = 'Moosas Face UID Labels'
        labels_group.set_attribute(FACE_UID_LABEL_DICTIONARY, FACE_UID_LABEL_KEY, true)

        uid_by_persistent_id = {}
        recognized_faces = []
        if defined?(MMR)
            recognized_faces = MMR.all_recognized_faces
        end
        if recognized_faces.empty? && defined?($current_model) && $current_model
            recognized_faces = $current_model.get_all_face
        end
        recognized_faces.each do |moosas_face|
                next unless moosas_face.face && moosas_face.face.valid?
                uid = moosas_face.uid || moosas_face.id
                uid_by_persistent_id[moosas_face.face.persistent_id] = uid unless uid.nil?
        end

        self.traverse_faces(model.entities) do |face, path|
            next unless $define_materials.empty? || $define_materials.has_key?(face.persistent_id)
            uid = uid_by_persistent_id[face.persistent_id]
            next if uid.nil?
            point = self.face_world_centroid(face, path)
            labels_group.entities.add_text("UID:#{uid}", point) if point
        end
        @face_uid_labels_group = labels_group
    end

    def self.remove_face_uid_labels(model)
    # Remove marked UID label groups from the model. Searching by attribute
    # makes cleanup work even when MoosasRender.rb was reloaded.
        groups = model.entities.grep(Sketchup::Group).select do |group|
            group.get_attribute(FACE_UID_LABEL_DICTIONARY, FACE_UID_LABEL_KEY) == true
        end
        groups.each { |group| group.erase! if group.valid? }
        @face_uid_labels_group = nil
    end

    def self.face_world_centroid(face, path)
        return nil if face.vertices.empty?
        transformation = path.inject(Geom::Transformation.new) do |total, container|
            total * container.transformation
        end
        points = face.vertices.map { |vertex| transformation * vertex.position }
        count = points.length.to_f
        Geom::Point3d.new(
            points.sum { |point| point.x } / count,
            points.sum { |point| point.y } / count,
            points.sum { |point| point.z } / count
        )
    end

    def self.show_entity_type(model,type_index)
    # """
    # Function
    # --------
    # Displays faces of a specified type in the model while hiding all others.
    # 
    # Parameters
    # ----------
    # model : Sketchup::Model
    # The Sketchup model containing the faces to be processed.
    # type_index : Integer
    # The type index used to filter and show only faces matching this type.
    # 
    # Returns
    # -------
    # None
    # This method does not return a value. It modifies the visibility of faces in the model.
    # """
        Sketchup.active_model.start_operation("标记面的类型#{type_index}", true)
        self.hide_all_face
        moosas_faces = model.get_all_face
        moosas_faces.each do |mf|
            if mf.type == type_index
                mf.face.hidden = false
            end
        end
        Sketchup.active_model.commit_operation
    end

    def self.traverse_faces(entity, path=[], &func)
    # """
    # Function
    # --------
    # Recursively traverses a hierarchy of SketchUp entities to find and process all Face objects.
    # 
    # This method is designed to walk through groups, component instances, and collections of entities,
    # applying a given function to each Sketchup::Face encountered. The traversal maintains the path
    # from the root to the current face, which can be passed to the provided function.
    # 
    # Parameters
    # ----------
    # entity : Sketchup::Entity or Enumerable
    # The starting entity or collection to traverse. Can be a single entity such as a Face,
    # Group, or ComponentInstance, or a collection such as Entities, Selection, or any Enumerable.
    # path : Array, optional
    # A list representing the ancestral path of groups or components leading to the current entity.
    # Used internally during recursion to track context. Defaults to an empty array.
    # func : Proc or lambda
    # A callable that will be invoked for each Sketchup::Face found. Its argument signature determines
    # how it's called:
    # - If `func.arity == 1`, it is called with just the face: `func.call(face)`
    # - Otherwise, it is called with both the face and the path: `func.call(face, path)`
    # 
    # Returns
    # -------
    # None
    # This method does not return a value. It is intended for side effects via the provided function.
    # """
        case entity
        when Sketchup::Face
            func.arity == 1 ? func.call(entity) : func.call(entity, path)
        when Sketchup::Group 
            traverse_faces(entity.entities, path + [entity], &func)
        when Sketchup::ComponentInstance
            traverse_faces(entity.definition.entities, path + [entity], &func)
        when Sketchup::Entities, Sketchup::Selection, Enumerable
            entity.each {|e| traverse_faces(e,path,&func)}
        end
    end

    def self.show_all_face
    # """
    # Function
    # --------
    # show_all_face :
    # Displays all hidden faces in the active SketchUp model by setting their hidden attribute to false.
    # 
    # Parameters
    # ----------
    # None
    # This is a class method that operates on the active model's entities. It does not take any explicit parameters.
    # 
    # Returns
    # -------
    # nil
    # This method does not return a value. It performs an action (modifying entity visibility) within the SketchUp model.
    # """
        self.traverse_faces(Sketchup.active_model.entities) do |e,path|
            e.hidden = false
        end
    end

    def self.show_space(model,id)
    # """
    # Function
    # --------
    # show_space
    # Finds the index of a space in the model by its ID, stores the index in a global variable,
    # and selects the walls of that space using an external module function.
    # 
    # Parameters
    # ----------
    # model : object
    # A model object that contains a collection of spaces. It is expected to have a `spaces`
    # attribute which behaves like a list or array of space objects.
    # id : int
    # The unique identifier of the space to be found within the model's spaces collection.
    # 
    # Returns
    # -------
    # None
    # This method does not return any value. Its primary effect is modifying the global
    # variable `$space_select_index` and invoking `MMR.select_space_walls` to select walls
    # associated with the identified space.
    # """
        for i in 0..model.spaces.length-1
            if model.spaces[i].id==id
                $space_select_index=i
                break
            end
        end
        MMR.select_space_walls($space_select_index)
    end

    def self.hide_all_face
    # Function:
    # Hides all faces within the active model's entities by traversing through them and setting their visibility to hidden.
    # 
    # Parameters:
    # None
    # 
    # Returns:
    # nil : This method does not return a value.
        self.traverse_faces(Sketchup.active_model.entities) do |e,path|
            e.hidden = true
        end
    end
    def self.hide_glazing
    # """
    # Function
    # --------
    # Hides all glazing faces within the active SketchUp model by traversing the entities collection.
    # 
    # Parameters
    # ----------
    # None
    # This is a class method that operates on the active model's entities. It does not accept any parameters.
    # 
    # Returns
    # -------
    # nil
    # This method does not return a value. It performs an action (hiding glazing faces) and returns nil implicitly.
    # """
        self.traverse_faces(Sketchup.active_model.entities) do |e,path|
            if MMR.is_glazing(e)
                e.hidden = true
            end
        end
    end

    def self.load_entity_materials
    # """
    # Function
    # --------
    # Load and initialize entity-specific materials in the SketchUp model.
    # 
    # This method checks if entity materials have already been loaded into the class variable `@entity_materials`.
    # If not, it calculates a texture size based on the model's bounding box diagonal, then creates or updates
    # SketchUp materials for various building elements (e.g., walls, glazing, floors) using predefined image textures.
    # Each material is assigned a unique name prefixed with 'moosas_' and linked to a corresponding PNG texture file.
    # 
    # Parameters
    # ----------
    # None
    # 
    # Returns
    # -------
    # Hash[int => String]
    # A hash mapping integer constants (from MoosasConstant) representing entity types to string identifiers
    # used in material naming and texture lookup. The keys are entity type constants, and the values are
    # lowercase string labels (e.g., "wall", "glazing") used to construct texture paths and material names.
    # """
        if @entity_materials != nil && @entity_materials.values.all? { |name| Sketchup.active_model.materials['moosas_' + name] }
            return @entity_materials
        end
        d = Sketchup.active_model.bounds.diagonal
        size = 50 + 50 * (d/800)

        dir = MPath::UI+"images/"

        #if not Sketchup.active_model.materials["test_material"]
        #    ignore_material = Sketchup.active_model.materials.add("test_material")
        #    ignore_material.texture = dir + "checkerboard.png"
        #    ignore_material.color = "Gray"
        #    ignore_material.texture.size = size
        #end
        

        @entity_materials = {
          MoosasConstant::ENTITY_WALL => "wall",
          MoosasConstant::ENTITY_INTERNAL_WALL => "internalwall",
          MoosasConstant::ENTITY_GLAZING => "glazing",
          MoosasConstant::ENTITY_INTERNAL_GLAZING => "internalglazing",
          MoosasConstant::ENTITY_SKY_GLAZING => "skyglazing",
          MoosasConstant::ENTITY_ROOF => "roof",
          MoosasConstant::ENTITY_FLOOR => "floor",
          MoosasConstant::ENTITY_GROUND_FLOOR => "groundfloor",
          MoosasConstant::ENTITY_SHADING => "shading",
          MoosasConstant::ENTITY_PARTY_WALL => "partywall",
          MoosasConstant::ENTITY_DOOR => "door",
          MoosasConstant::ENTITY_AIRWALL => "airwall",
          MoosasConstant::ENTITY_SURROUNDING => "surrounding",
          MoosasConstant::ENTITY_IGNORE => "ignore"
        }

        @entity_materials.keys.each do |k|
            mat_name = "moosas_" + @entity_materials[k]
            material = Sketchup.active_model.materials[mat_name] || Sketchup.active_model.materials.add(mat_name)
            material.texture = dir +  "textures/texture_" + @entity_materials[k] + ".png"
            material.texture.size = size
            #material.alpha = mat_name.include?("glazing") ? 0.95 : 1.0

        end

        return @entity_materials
    end

    def self.moosas_material_lib
    # Function:
    # Returns the material library for entities, initializing it if necessary.
    # 
    # Parameters:
    # None
    # 
    # Returns:
    # Hash: A hash containing entity materials. If the material library has not been initialized,
    # it is loaded by calling `load_entity_materials` before being returned. The instance
    # variable `@entity_materials` holds the material data.
        if @entity_materials == nil
            self.load_entity_materials
        end
        return @entity_materials
    end


end
