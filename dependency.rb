require 'project'

main = Main.new(:ignore_missing_dependencies => true)
main.ask_root_dir
main.process
while true do
  main.ask_root_project
  main.tell_dependencies
end
