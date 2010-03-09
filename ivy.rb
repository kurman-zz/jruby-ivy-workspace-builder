require 'java'
require 'ivy.jar'

module IvyMod
  include_package 'org.apache.ivy'
end

module JavaMod
  include_package 'java.io'
  include_package 'java.lang'
end

class Ivy
  
  def initialize(dependencies, target_dir, ivy_setting_file_path)
    @ivy = IvyMod::Ivy.newInstance()
    @settings = @ivy.getSettings()
    @target_dir = target_dir
    set_realm
    set_hanlders
    @ivy.configure(JavaMod::File.new(ivy_setting_file_path))
    @ivy.pushContext()
    set_cache
    
    @confs = ["*"].to_java :String 
    
    @ivyfile = JavaMod::File.createTempFile("ivy", ".xml")
    @ivyfile.deleteOnExit()
    
    @moduleDescriptor = org.apache.ivy.core.module.descriptor.DefaultModuleDescriptor.newDefaultInstance(
                          org.apache.ivy.core.module.id.ModuleRevisionId.newInstance('RAD-workspace-builder', 'workspace-builder-caller', 'working'))
    
    dependencies.each do |dependency|
      dependencyDescriptor = org.apache.ivy.core.module.descriptor.DefaultDependencyDescriptor.new(@moduleDescriptor,
                            org.apache.ivy.core.module.id.ModuleRevisionId.newInstance(
                                dependency.organization, dependency.name, dependency.revision), false, false, true)
      @confs.each do |conf|
        dependencyDescriptor.addDependencyConfiguration("default", conf)
      end
      @moduleDescriptor.addDependency(dependencyDescriptor)
    end
    
    org.apache.ivy.plugins.parser.xml.XmlModuleDescriptorWriter.write(@moduleDescriptor, @ivyfile)
  end
  
  def retrieve
      resolveOptions = 
          org.apache.ivy.core.resolve.ResolveOptions.new.setConfs(@confs).setValidate(true).setArtifactFilter(
            org.apache.ivy.util.filter.FilterHelper.getArtifactTypeFilter('jar'))
      resolveReport = @ivy.resolve(@ivyfile.toURI().toURL(), resolveOptions)
      raise "Could not resolve dependency" if resolveReport.hasError()
      
      puts "#{@target_dir}/[artifact]-[revision](-[classifier]).[ext]"
      @ivy.retrieve(@moduleDescriptor.getModuleRevisionId(), "#{@target_dir}/[artifact]-[revision](-[classifier]).[ext]", 
          org.apache.ivy.core.retrieve.RetrieveOptions.new().setConfs(@confs).setSync(true).setUseOrigin(true).setArtifactFilter(
            org.apache.ivy.util.filter.FilterHelper.getArtifactTypeFilter('jar'))
          )
          
      jar_file_names = resolveReport.getAllArtifactsReports().collect do |artifact_report|
        artifact_report.getLocalFile.getName
      end
      
      jar_file_names.uniq
  end
  
private
  
  def set_logger
    @ivy.getLoggerEngine().pushLogger(org.apache.ivy.util.DefaultMessageLogger.new(org.apache.ivy.util.Message::MSG_DEBUG))
  end
  
  def set_realm
    org.apache.ivy.util.url.CredentialsStore::INSTANCE.addCredentials(realm=nil, host=nil, username=nil, passwd=nil)
  end
  
  def set_hanlders
    dispatcher = org.apache.ivy.util.url.URLHandlerDispatcher.new;
    httpHandler = org.apache.ivy.util.url.URLHandlerRegistry.getHttp();
    dispatcher.setDownloader("http", httpHandler);
    dispatcher.setDownloader("https", httpHandler);
    org.apache.ivy.util.url.URLHandlerRegistry.setDefault(dispatcher);
  end
  
  def set_cache
    @cache = JavaMod::File.new(@settings.getDefaultCache().getAbsolutePath())
    @cache.mkdirs unless @cache.exists?
  end
  
end

