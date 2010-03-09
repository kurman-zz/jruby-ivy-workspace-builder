require "java"
require 'ivy'

require 'erb'
require 'fileutils'
require "rexml/document"
require 'set'

include REXML

class String
  def special_folder?
    self =~ /^\./
  end

  def ignore_in_eclipse?
    ['.classpath', '.project', '.externalToolBuilders', '.svn', '.runtime', 'bin', 'lib'].index self
  end

  def source_dir?
    ['src', 'test', 'resources', 'resource', 'conf', 'ejbModule', 'JavaSource'].index self
  end
  
  def test_dir?
    ['test'].index self
  end
  
  def empty_dir?
    dir = Dir.new(self).entries.find do |entry|
      not entry.special_folder?
    end
    dir.nil?
  end
  
  def ivy_file_exists?
    Dir.new(self).entries.each do | file |
      return true if file =~ /^ivy\.xml$/
    end
    false
  end
  
  def expand_path_with(another_dir_or_file)
    File.expand_path(File.join(self, another_dir_or_file))
  end
  
  def blank?
    self.chomp == ''
  end
  
  def subdirectories
    Dir.new(self).entries.inject([]) do | child_directories, file |
      file_path = expand_path_with(file)
      child_directories << file_path if File.directory?(file_path) and !file.special_folder?
      child_directories
    end
  end
  
end


class Dependency
  attr_reader :name, :organization, :revision, :configurations
  attr_reader :owning_project

  def initialize(owning_project, name, organization, revision, configurations)
    @owning_project = owning_project
    @name = name
    @organization = organization
    @revision = revision
    @revision = '0.0+' if source_dependency? and revision =~ /gid.release/
    @configurations = configurations.split(';')
  end
  
  def runtime?
    @configurations.include? 'runtime'
  end
  
  def source_dependency?
    
  end
  
end

class Project
  PROJECT_TEMPLATE_FILE_NAME = './project_template.erb'
  CLASSPATH_TEMPLATE_FILE_NAME = './classpath_template.erb'
  
  MODULES_TO_IGNORE = ['release', 'soa', 'tangosol', 'tax', 'tools']
  DEPENDENCIES_TO_IGNORE =  []
    
  attr_accessor :name, :organization, :revision, :configurations
  attr_reader :module_name, :dependencies, :project_directory
  attr_accessor :should_be_created
  
  def initialize(ivy_xml_document, project_directory, options={})
    @module_name = XPath.first(ivy_xml_document, '//info/attribute::module').to_s
    @dependencies = instantiate_dependencies(ivy_xml_document)
    @project_directory = project_directory
    
    @name = @module_name
    @revision = '0.0+'
    @organization = XPath.first(ivy_xml_document, '//info/attribute::organisation').to_s
    
    @traversal_is_done = false
    @should_be_created = false
    @options = options
  end
  
  def should_ignore_missing_dependency?(module_name, dependency)
    MODULES_TO_IGNORE.include?(module_name) or DEPENDENCIES_TO_IGNORE.include?(dependency.name) or @options[:ignore_missing_dependencies]
  end
  
  def link_to_dependent_projects!(list_of_projects)
    dependencies_to_replace = []
    projects_to_add = []
    # TODO clean this up
    source_dependencies.each do | dependency |
      target_project = list_of_projects.find do |project| 
        project.module_name == dependency.name
      end
      if not should_ignore_missing_dependency?(module_name, dependency)
        raise "Could not find target project for dependency '#{dependency.name}' in module '#{@module_name}' in #{@project_directory}" if target_project.nil?
      else
        puts "Could not find target project for dependency '#{dependency.name}' in module '#{@module_name}' in #{@project_directory}" if target_project.nil?
      end
      puts "Project is not available: #{dependency.name} in #{@module_name}" if target_project.nil?
      dependencies_to_replace << dependency
      if target_project
        projects_to_add << target_project
        target_project.configurations = dependency.configurations
      end
    end
    @dependencies -= dependencies_to_replace
    @dependencies += projects_to_add
    @traversal_is_done = true
  end
  
  def create_eclipse_projects(target_dir, projects_to_create, created_projects=Set.new)
    definitions = {:dependencies => Set.new, :projects => Set.new}
    source_dependencies.each do |source_dependency|
      subproject_definitions = source_dependency.create_eclipse_projects(target_dir, projects_to_create, created_projects)
      definitions[:dependencies] = definitions[:dependencies].merge(subproject_definitions[:dependencies])
      definitions[:projects] = definitions[:projects].merge(subproject_definitions[:projects])
    end
    
    if projects_to_create.include?(self) 
      unless created_projects.include?(self)
        definitions[:dependencies] = definitions[:dependencies].merge(@dependencies)
        create_eclipse_project target_dir, definitions, created_projects
        created_projects.add self
      end
      definitions = {:dependencies => Set.new, :projects => Set.new([self]) }
    else
      definitions[:dependencies] = definitions[:dependencies].merge(runtime_dependencies)
      definitions[:dependencies].add self
    end
    return definitions
  end
  
  def create_eclipse_project(target_dir, definitions, created_projects)
    puts "CREATING PROJECT '#{module_name}'"
    create_project_folder(target_dir)
    dependencies_without_created_projects = definitions[:dependencies] - created_projects.to_a
    jar_file_names = Ivy.new(dependencies_without_created_projects, File.join(target_dir, @module_name, 'lib'), 'ivysettings.xml').retrieve
    jar_file_names = jar_file_names.collect{|jar_file_name| "lib/#{jar_file_name}"}
    details = project_files_details
    details.merge! :libs => jar_file_names
    write_project_info_file(target_dir, details)
    write_classpath_info_file(target_dir, details, definitions[:projects])
    
  end
  
  def runtime_dependencies
    @dependencies.select do |dependency|
      dependency.runtime?
    end
  end
  
  def source_projects_tree
    projects = [self] + source_projects.inject([]) {|projects, source_project| projects + source_project.source_projects_tree }
    projects.uniq
  end
  
  def hash 
    @module_name.hash
  end 

  def eql?(other)
    @module_name.eql?(other.module_name) 
  end

  def output_dependencies(spacing=0)
    puts "#{' '*spacing}ROOT: #{module_name}"
    dependencies.each do |dependency|
      puts "#{' '*spacing} - #{dependency.name}"
      dependency.target_project.output_dependencies(spacing+2) if dependency.source_dependency?
    end
    
  end
  
  def to_s
    return "#{@module_name}: #{@project_directory}"
  end
  
  def source_dependency?
    true
  end
  
  def runtime?
    @configurations.include? 'runtime'
  end
  
private

  def instantiate_dependencies(ivy_xml_document)
    dependencies = XPath.match(ivy_xml_document, '//dependencies/dependency').collect do |dependency_node|
      Dependency.new(self, dependency_node.attributes['name'].to_s, 
                      dependency_node.attributes['org'].to_s, dependency_node.attributes['rev'].to_s, 
                      dependency_node.attributes['conf'].to_s) unless dependency_node.attributes['name'].to_s =='junit'
    end
    dependencies.compact
  end
  
  def source_projects
    raise "linking of projects has not been done yet" unless @traversal_is_done
    source_dependencies.each do | dependency|
      raise "dependency #{dependency.name} missing target project for project #{module_name}." if dependency.class != Project
    end
    source_dependencies
  end
  
  def source_dependencies
    @dependencies.select{|dependency| dependency.source_dependency?}
  end

  def binary_dependencies(projects_to_create)
    @dependencies - projects_to_create
  end
  
  def create_project_folder(target_dir)
    puts "Creating project folder for '#{@module_name}'"
    FileUtils.mkdir File.join(target_dir, @module_name)
  end
  
  def project_files_details
    details = {:project_name  => @module_name, :files => [], :folders => [], :has_tests => false}
    Dir.new(@project_directory).entries.each do | file |
      unless file.ignore_in_eclipse?
        file_path = @project_directory.expand_path_with(file)
        if File.directory?(file_path) 
          details[:folders] << {:name => file, :path => file_path, :source => file.source_dir?} unless file.special_folder?
          details[:has_tests] = true if file.test_dir?
        else
          details[:files] << {:name => file, :path => file_path}
        end
      end
    end
    details
  end
  
  def write_project_info_file(target_dir, details)
    template = ERB.new(File.new(PROJECT_TEMPLATE_FILE_NAME).read)
    project_settings = details
    project_file = File.new(File.join(target_dir, @module_name, '.project'), 'w')
    project_file.write(template.result(binding))
    project_file.close    
  end
  
  def write_classpath_info_file(target_dir, details, project_dependencies)
    template = ERB.new(File.new(CLASSPATH_TEMPLATE_FILE_NAME).read)
    project_settings = details
    # source_dependencies = dependencies.select {|dependency| projects_to_create.include? dependency}
    project_file = File.new(File.join(target_dir, @module_name, '.classpath'), 'w')
    project_file.write(template.result(binding))
    project_file.close  
  end
  
end


class Main
  attr_reader :root_dir, :linked_projects, :target_dir
  attr_reader :root_project
  
  DIRECTORIES_TO_IGNORE = ['commerce/workspace', 'build/target', 'build/buildeng/app-specific']
  
  def initialize(options={})
    @root_dir ="/Users/kurman/workspace/"
    @linked_projects = []
    @target_dir = '/Users/kurman/workspace/my_projects'
    @options = options
  end
  
  def ask_root_dir
    puts "Root directory['#{@root_dir}']:"
    user_specified_dir = gets.chomp
    @root_dir = user_specified_dir unless user_specified_dir.blank?
  end
  
  def ask_root_project
    while true
      puts "Root project:"
      root_project_name = gets.chomp
      @root_project = @linked_projects.find{|project| project.module_name == root_project_name}
      if @root_project.nil?
        puts "Project '#{root_project_name}' not found!"
      else
        break
      end
    end
  end
  
  def ask_target_dir
    puts "Target dir['#{@target_dir}']:"
    user_specified_dir = gets.chomp
    @target_dir = user_specified_dir.blank? ? @target_dir : user_specified_dir
    raise "dir is not empty! Clean the directory." unless @target_dir.empty_dir?
  end
  
  def ask_projects_to_create
    @selection = {}
    @root_project.source_projects_tree.each_with_index do |project, index|
      @selection[index + 1] = project
    end

    while true do
      @selection.each do |index, project|
        puts "#{index}. #{project.module_name} #{project.should_be_created ? ' -> will be created' : ''}"
      end
      input=gets.chomp
      break if input == '.'
      @selection[input.to_i].should_be_created = true
      puts; puts; puts
    end
  end
  
  def create_projects
    puts "creating projects"
    source_projects = @selection.values.select{|project| project.should_be_created}
    @root_project.create_eclipse_projects(@target_dir, source_projects)
  end
  
  def tell_dependencies
    puts "First level dependency for #{@root_project.name} ---"
    puts ""
    @root_project.dependencies.each do |dependency| 
      puts "  #{dependency.name}" if dependency.source_dependency?
    end
    puts "----"
    puts ""
    # puts "All projects --"
    # @root_project.dependencies.each do |dependency| 
    #   puts "  #{dependency.name}"
    # end
    # puts "----"
    
  end
  
  def process
    all_projects = projects
    all_projects.each do |project|
      project.link_to_dependent_projects!(all_projects)
      linked_projects << project
    end
  end

  def projects
    all_ivy_files_in(@root_dir).inject([]) do |projects, ivy_file|
      begin
        projects << Project.new(Document.new(File.new(ivy_file)), File.dirname(ivy_file), @options)
      rescue Exception => e
        puts "Error processing #{ivy_file} : #{e}"
        raise e
      end
      projects
    end
  end

private

  def all_ivy_files_in(directory)
    DIRECTORIES_TO_IGNORE.each do |directory_to_ignore|
      if directory.index directory_to_ignore
        puts "Ignoring #{directory}"
        return []
      end
    end

    raise "Not a directory: #{directory}" unless File.directory? directory
    return [File.expand_path(File.join(directory, 'ivy.xml'))] if directory.ivy_file_exists?

    project_listing = []
    directory.subdirectories.inject(project_listing) do |project_listing, child_directory|
      all_ivy_files_in(child_directory).each { |listing| project_listing << listing }
      project_listing
    end    
    project_listing
  end
  
end

