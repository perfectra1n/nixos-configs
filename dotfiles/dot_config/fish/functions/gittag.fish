function gittag --description "create and push a git tag"
	git tag $argv
	git push origin $argv
end
