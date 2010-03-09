require 'project'

main = Main.new
main.ask_root_dir
main.process
main.ask_root_project
main.ask_target_dir
main.ask_projects_to_create
main.create_projects
