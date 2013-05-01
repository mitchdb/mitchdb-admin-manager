SOURCEMOD=../sourcemod/sourcemod-1.5.0-hg3832/addons/sourcemod/scripting
CURL=../sourcemod/curl/scripting/include
PLUGINS=addons/sourcemod/plugins
SCRIPTING=addons/sourcemod/scripting

compile: clean
	$(SOURCEMOD)/spcomp $(SCRIPTING)/mitchdb_admin_mgr.sp -o$(PLUGINS)/mitchdb_admin_mgr.smx -i$(SCRIPTING) -i$(SOURCEMOD)/include -i$(CURL) -v2

clean:
	rm -f $(PLUGINS)/mitchdb_admin_mgr.smx

zip: compile
	rm -f mitchdb_admin_mgr.zip
	zip -r mitchdb_admin_mgr.zip $(PLUGINS)/mitchdb_admin_mgr.smx

tag: compile
	# git tag -a v2.0.0 -m "Version 2.0.0"
	# git push --tags