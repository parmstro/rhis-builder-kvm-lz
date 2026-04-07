## Roles for managing imagebuilder on premise with Satellite

Fork it. Clone it. Configure it. Test it. Change it. Commit it. Create a PR.

***

This project is designed to help setup Imagebuilder in on premise VMs for delivering VM images. 
Images can be provided to any of the existing Satellite compute resources.
The project is targeting the following workflow.

- define content, including filtering                     [rhis-builder-satellite]
- define target for deployment                            [variable]
- build imagebuilder system if not exists (arch + major)  [ansible play CreateHostFromHostgroup.yml]
- configure imagebuilder instance for content definition  [role: soe-image-configure]
- define image blueprint                                  [variable] 
- compose image from blueprint                            [role: soe-image-compose]
- upload image to target                                  [role: soe-image-upload]
- register image with Satellite compute resource          [role: soe-image-register]

See rhis-builder-vault-SAMPLE repo for secrets definitions.
