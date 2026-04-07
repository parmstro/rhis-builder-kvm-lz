### imagebuilder-lce-cv

This role assigns the specified imagebuilder instance host to the defined Satellite Lifecycle Environment (lce) and Content View (cv).
The assigned content view is the active version of content view or composite content view that exists within the specified lifecycle environment.
Satellite currently does not allow selecting multiple active versions within a lifecycle environment.
To achieve having a specific version of a content view in a particular environment, you can promote that specific version from the library to the target lce. This will make that specific version the active version in the lifecycle environment.

The role then 
- creates the /etc/osbuild-composer/repositories directory with the appropriate ownership if it doesn't exist
- creates or overwrites the base template in the /etc/osbuild-composer/repositories for the major version of the OS of the imagebuilder host
- restarts the osbuild-composer service
- verifies that it can contact the Satellite system and find content.

The imagebuilder system is now ready to build images based on the specified content view.