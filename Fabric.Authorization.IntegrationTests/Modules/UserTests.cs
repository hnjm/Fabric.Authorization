﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Claims;
using System.Threading.Tasks;
using Fabric.Authorization.API.Constants;
using Fabric.Authorization.API.Models;
using IdentityModel;
using Nancy;
using Nancy.Testing;
using Newtonsoft.Json;
using Xunit;

namespace Fabric.Authorization.IntegrationTests.Modules
{
    [Collection("InMemoryTests")]
    public class UserTests : IClassFixture<IntegrationTestsFixture>
    {
        private static readonly string Group1 = Guid.Parse("A9CA0300-1006-40B1-ABF1-E0C3B396F95F").ToString();
        private static readonly string Source1 = "Source1";

        private static readonly string Group2 = Guid.Parse("ad2cea96-c020-4014-9cf6-029147454adc").ToString();
        private static readonly string Source2 = "Source2";

        private static readonly string IdentityProvider = "idP1";

        private readonly Browser _browser;
        private readonly string _securableItem;
        public UserTests(IntegrationTestsFixture fixture, string storageProvider = StorageProviders.InMemory)
        {
            _securableItem = "userprincipal" + Guid.NewGuid();
            var principal = new ClaimsPrincipal(
                new ClaimsIdentity(new List<Claim>
                {
                    new Claim(Claims.Scope, Scopes.ManageClientsScope),
                    new Claim(Claims.Scope, Scopes.ReadScope),
                    new Claim(Claims.Scope, Scopes.WriteScope),
                    new Claim(Claims.ClientId, _securableItem),
                    new Claim(Claims.Sub, _securableItem),
                    new Claim(JwtClaimTypes.Role, Group1),
                    new Claim(JwtClaimTypes.Role, Group2),
                    new Claim(JwtClaimTypes.IdentityProvider, IdentityProvider)
                }, _securableItem));
            
            _browser = fixture.GetBrowser(principal, storageProvider);
            fixture.CreateClient(_browser, _securableItem);
            Task.Run(async () => await fixture.AssociateUserToAdminRoleAsync(_securableItem, IdentityProvider, storageProvider,
                Domain.Defaults.Authorization.AppGrain, _securableItem, $"{_securableItem}-admin")).Wait();
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task GetUserPermissions_NonAuthenticatedUserWithPermissions_SuccessAsync()
        {
            var groupName = "Admin" + Guid.NewGuid();
            var roleName = "Administrator" + Guid.NewGuid();
            var permissionNames = new[] { "viewpatients" + Guid.NewGuid(), "editpatients" + Guid.NewGuid(), "adminpatients" + Guid.NewGuid(), "deletepatients" + Guid.NewGuid() };

            const string subjectId = "first.last";
            const string identityProvider = "Windows";

            // add custom group
            var response = await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new GroupRoleApiModel
                {
                    GroupName = groupName,
                    GroupSource = "Custom"
                });
            });

            Assert.Equal(HttpStatusCode.Created, response.StatusCode);

            // add role
            response = await _browser.Post("/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new RoleApiModel
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = roleName
                });
            });

            Assert.Equal(HttpStatusCode.Created, response.StatusCode);

            var roleId = response.Body.DeserializeJson<RoleApiModel>().Id;

            // add role to group
            response = await _browser.Post($"/groups/{groupName}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = roleId.ToString()
                });
            });

            Assert.Equal(HttpStatusCode.Created, response.StatusCode);

            // add 4 permissions
            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[0]
                });
            });

            var permission1Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[1]
                });
            });

            var permission2Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[2]
                });
            });

            var permission3Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[3]
                });
            });

            var permission4Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            // add user to group
            response = await _browser.Post($"/groups/{groupName}/users", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    SubjectId = subjectId,
                    IdentityProvider = identityProvider
                });
            });

            Assert.Equal(HttpStatusCode.Created, response.StatusCode);

            var permissionApiModels = new List<PermissionApiModel>
            {
                new PermissionApiModel
                {
                    Id = permission1Id,
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[0],
                    PermissionAction = PermissionAction.Allow
                },
                new PermissionApiModel
                {
                    Id = permission2Id,
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[1],
                    PermissionAction = PermissionAction.Deny
                },
                new PermissionApiModel
                {
                    Id = permission3Id,
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[2],
                    PermissionAction = PermissionAction.Allow
                },
                new PermissionApiModel
                {
                    Id = permission4Id,
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionNames[3],
                    PermissionAction = PermissionAction.Deny
                }
            };

            // create 2 role-based permissions
            response = await _browser.Post($"/roles/{roleId}/permissions", with =>
            {
                with.HttpRequest();

                with.Body(JsonConvert.SerializeObject(
                    new List<PermissionApiModel> { permissionApiModels[0], permissionApiModels[1] }));

            });

            Assert.Equal(HttpStatusCode.Created, response.StatusCode);

            // create 2 granular (user-based) permissions
            response = await _browser.Post($"/user/{identityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();

                with.Body(JsonConvert.SerializeObject(
                    new List<PermissionApiModel> { permissionApiModels[2], permissionApiModels[3] }));

            });

            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);

            // retrieve permissions for user
            response = await _browser.Get($"/user/{identityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
            });

            var permissions = response.Body.DeserializeJson<List<ResolvedPermissionApiModel>>();

            Assert.NotNull(permissions);
            Assert.Equal(4, permissions.Count);

            var permission1 = permissions.FirstOrDefault(p => p.Name == permissionNames[0]);
            Assert.NotNull(permission1);
            Assert.Equal(PermissionAction.Allow, permission1.PermissionAction);
            Assert.Single(permission1.Roles);

            var permission3 = permissions.FirstOrDefault(p => p.Name == permissionNames[2]);
            Assert.NotNull(permission3);
            Assert.Equal(PermissionAction.Allow, permission3.PermissionAction);
            Assert.Empty(permission3.Roles);
            Assert.NotEqual(DateTime.MinValue, permission3.CreatedDateTimeUtc);

            var permission4 = permissions.FirstOrDefault(p => p.Name == permissionNames[3]);
            Assert.NotNull(permission4);
            Assert.Equal(PermissionAction.Deny, permission4.PermissionAction);
            Assert.Empty(permission4.Roles);
            Assert.NotEqual(DateTime.MinValue, permission4.CreatedDateTimeUtc);
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_AddGranularPermission_AllowDenyPermissionInSameRequestAsync()
        {
            var permissionName = "readpatient" + Guid.NewGuid();
            var allowReadPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = permissionName,
                PermissionAction = PermissionAction.Allow
            };

            var denyReadPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = permissionName,
                PermissionAction = PermissionAction.Deny
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(allowReadPatientPermission);
            });

            allowReadPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;
            denyReadPatientPermission.Id = allowReadPatientPermission.Id;

            string subjectId = _securableItem;

            var postResponse = await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { allowReadPatientPermission, denyReadPatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.Conflict, postResponse.StatusCode);
            Assert.Contains($"The following permissions cannot be specified as both 'allow' and 'deny': app/{subjectId}.{permissionName}", postResponse.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_AddGranularPermission_DuplicateAsync()
        {
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            var postResponse = await _browser.Post($"/user/{IdentityProvider}/{subjectId.ToUpper()}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.Conflict, postResponse.StatusCode);
            Assert.Contains(
                $"The following permissions already exist as 'allow' permissions: app/{subjectId}.{modifyPatientPermission.Name}",
                postResponse.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_AddGranularPermission_ExistWithOtherAction_DuplicateAsync()
        {
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var deletePatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "deletepatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var readPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "readpatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(deletePatientPermission);
            });

            deletePatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(readPatientPermission);
            });

            readPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel>
                {
                    modifyPatientPermission,
                    deletePatientPermission,
                    readPatientPermission
                };
                with.JsonBody(perms);
            });

            modifyPatientPermission.PermissionAction = PermissionAction.Deny;

            var postResponse = await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel>
                {
                    modifyPatientPermission,
                    deletePatientPermission,
                    readPatientPermission
                };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.Conflict, postResponse.StatusCode);
            Assert.Contains(
                $"The following permissions exist as 'allow' and cannot be added as 'deny': app/{_securableItem}.{modifyPatientPermission.Name}",
                postResponse.Body.AsString());
            Assert.Contains(
                $"The following permissions already exist as 'allow' permissions: app/{_securableItem}.{deletePatientPermission.Name}, app/{_securableItem}.{readPatientPermission.Name}",
                postResponse.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_AddGranularPermissions_NoPermissionsInBodyAsync()
        {
            var subjectId = _securableItem;

            var postRequest = await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel>();
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.BadRequest, postRequest.StatusCode);
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_AddGranularPermssion_ExistsWithOtherActionAsync()
        {
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            modifyPatientPermission.PermissionAction = PermissionAction.Deny;

            var postResponse = await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.Conflict, postResponse.StatusCode);
            Assert.Contains(
                $"The following permissions exist as 'allow' and cannot be added as 'deny': app/{_securableItem}.{modifyPatientPermission.Name}",
                postResponse.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_Delete_SuccessAsync()
        {
            // Adding permission
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;
            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{_securableItem}.{modifyPatientPermission.Name}", permissions.Permissions);

            //delete the permission
            await _browser.Delete($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.DoesNotContain("app/{_securableItem}.{modifyPatientPermission.Name}", permissions.Permissions);
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_Delete_UserHasNoGranularPermissionsAsync()
        {
            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Single(permissions.Permissions);

            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var subjectId = _securableItem;

            //attempt to delete a permission the user does not have 
            var deleteRequest = await _browser.Delete($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.BadRequest, deleteRequest.StatusCode);
            Assert.Contains(
                $"The following permissions do not exist as 'allow' permissions: app/{_securableItem}.{modifyPatientPermission.Name}",
                deleteRequest.Body.AsString());
            Assert.DoesNotContain("The following permissions exist as 'deny' for user but 'allow' was specified",
                deleteRequest.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_Delete_WrongPermissionActionAsync()
        {
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{subjectId}.{modifyPatientPermission.Name}", permissions.Permissions);

            //attempt to delete modifyPatientPermission with permission action Deny
            modifyPatientPermission.PermissionAction = PermissionAction.Deny;

            var deleteRequest = await _browser.Delete($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.BadRequest, deleteRequest.StatusCode);
            Assert.Contains(
                $"The following permissions exist as 'allow' for user but 'deny' was specified: app/{subjectId}.{modifyPatientPermission.Name}",
                deleteRequest.Body.AsString());
            Assert.DoesNotContain("The permissions do not exist as 'deny' permissions", deleteRequest.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_Delete_WrongPermissionAction_InvalidPermissionAsync()
        {
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{_securableItem}.{modifyPatientPermission.Name}", permissions.Permissions);

            //attempt to delete modifyPatientPermission with permission action Deny and include an invalid permission
            modifyPatientPermission.PermissionAction = PermissionAction.Deny;

            var deletePatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "deletepatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var deleteRequest = await _browser.Delete($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission, deletePatientPermission };
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.BadRequest, deleteRequest.StatusCode);
            Assert.Contains(
                $"The following permissions exist as 'allow' for user but 'deny' was specified: app/{subjectId}.{modifyPatientPermission.Name}",
                deleteRequest.Body.AsString());
            Assert.DoesNotContain("The permissions do not exist as 'deny' permissions", deleteRequest.Body.AsString());
            Assert.Contains(
                $"The following permissions do not exist as 'allow' permissions: app/{subjectId}.{deletePatientPermission.Name}",
                deleteRequest.Body.AsString());
            Assert.DoesNotContain("The following permissions exist as 'deny' for user but 'allow' was specified",
                deleteRequest.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task Test_DeleteGranularPermissions_NoPermissionsInBodyAsync()
        {
            var subjectId = _securableItem;

            var deleteRequest = await _browser.Delete($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel>();
                with.JsonBody(perms);
            });

            Assert.Equal(HttpStatusCode.BadRequest, deleteRequest.StatusCode);
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task TestGetPermissions_SuccessAsync()
        {
            // Adding permissions
            var post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "viewpatient" + Guid.NewGuid()
                });
            });

            var viewPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "editpatient" + Guid.NewGuid()
                });
            });

            var editPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            var role = new RoleApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "viewer" + Guid.NewGuid(),
                Permissions = new List<PermissionApiModel> { viewPatientPermission }
            };

            post = await _browser.Post("/roles", with => // -3
            {
                with.HttpRequest();
                with.JsonBody(role);
            });

            var viewerRole = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -2
            {
                with.HttpRequest();
                role.Name = "editor" + Guid.NewGuid();
                role.Permissions = new List<PermissionApiModel> { editPatientPermission };
                with.JsonBody(role);
            });

            var editorRole = post.Body.DeserializeJson<RoleApiModel>();

            await _browser.Post($"/roles/{viewerRole.Id}/permissions", with =>
                {
                    with.HttpRequest();
                    with.JsonBody(new[]
                    {
                        viewPatientPermission
                    });
                });

            await _browser.Post($"/roles/{editorRole.Id}/permissions", with =>
                {
                    with.HttpRequest();
                    with.JsonBody(new[]
                    {
                        editPatientPermission
                    });
                });

            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group1,
                    GroupName = Group1,
                    GroupSource = Source1
                });
            });

            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group2,
                    GroupName = Group2,
                    GroupSource = Source2
                });
            });

            await _browser.Post($"/groups/{Group1}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = viewerRole.Identifier
                });
            });

            await _browser.Post($"/groups/{Group2}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = editorRole.Identifier
                });
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
                with.Header("Accept", "application/json");
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{_securableItem}.{editPatientPermission.Name}", permissions.Permissions);
            Assert.Contains($"app/{_securableItem}.{viewPatientPermission.Name}", permissions.Permissions);
            Assert.Equal(3, permissions.Permissions.Count());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task TestInheritance_SuccessAsync()
        {
            var group = Group1;

            // Adding permissions
            var post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "greatgrandfatherpermissions" + Guid.NewGuid()
                });
            });

            var ggfperm = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "grandfatherpermissions" + Guid.NewGuid()
                });
            });

            var gfperm = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "fatherpermissions" + Guid.NewGuid()
                });
            });

            var fperm = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "himselfpermissions" + Guid.NewGuid()
                });
            });

            var hsperm = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "sonpermissions" + Guid.NewGuid()
                });
            });

            var sonperm = post.Body.DeserializeJson<PermissionApiModel>();

            // Adding Roles
            var role = new RoleApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "greatgrandfather" + Guid.NewGuid(),
                Permissions = new List<PermissionApiModel> { ggfperm }
            };

            post = await _browser.Post("/roles", with => // -3
            {
                with.HttpRequest();
                with.JsonBody(role);
            });

            var ggf = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -2
            {
                with.HttpRequest();
                role.Name = "grandfather" + Guid.NewGuid();
                role.ParentRole = ggf.Id;
                role.Permissions = new List<PermissionApiModel> { gfperm };
                with.JsonBody(role);
            });

            var gf = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -1
            {
                with.HttpRequest();
                role.Name = "father" + Guid.NewGuid();
                role.ParentRole = gf.Id;
                role.Permissions = new List<PermissionApiModel> { fperm };
                with.JsonBody(role);
            });

            var f = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // 0
            {
                with.HttpRequest();
                role.Name = "himself" + Guid.NewGuid();
                role.ParentRole = f.Id;
                role.Permissions = new List<PermissionApiModel> { hsperm };
                with.JsonBody(role);
            });

            var hs = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // 1
            {
                with.HttpRequest();
                role.Name = "son" + Guid.NewGuid();
                role.ParentRole = hs.Id;
                role.Permissions = new List<PermissionApiModel> { sonperm };
                with.JsonBody(role);
            });

            post.Body.DeserializeJson<RoleApiModel>();

            // Adding groups
            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = group,
                    GroupName = group,
                    GroupSource = Source1
                });
            });

            await _browser.Post($"/groups/{group}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = hs.Identifier
                });
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            Assert.Contains(ggfperm.Name, get.Body.AsString());
            Assert.Contains(gfperm.Name, get.Body.AsString());
            Assert.Contains(fperm.Name, get.Body.AsString());
            Assert.Contains(hsperm.Name, get.Body.AsString());
            Assert.DoesNotContain(sonperm.Name, get.Body.AsString());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task TestRoleBlacklist_SuccessAsync()
        {
            // Adding permissions
            var post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "viewpatient" + Guid.NewGuid()
                });
            });

            var viewPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "editpatient" + Guid.NewGuid()
                });
            });

            var editPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            // Adding roles
            var role = new RoleApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "viewer" + Guid.NewGuid(),
                Permissions = new List<PermissionApiModel> { viewPatientPermission }
            };

            post = await _browser.Post("/roles", with => // -3
            {
                with.HttpRequest();
                with.JsonBody(role);
            });

            var viewerRole = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -2
            {
                with.HttpRequest();
                role.Name = "editor" + Guid.NewGuid();
                role.Permissions = new List<PermissionApiModel> { editPatientPermission };

                // Role denies viewPatient permission
                role.DeniedPermissions = new List<PermissionApiModel> { viewPatientPermission };
                with.JsonBody(role);
            });

            var editorRole = post.Body.DeserializeJson<RoleApiModel>();

            // Adding groups
            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group1,
                    GroupName = Group1,
                    GroupSource = Source1
                });
            });

            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group2,
                    GroupName = Group2,
                    GroupSource = Source2
                });
            });

            await _browser.Post($"/groups/{Group1}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = viewerRole.Identifier
                });
            });

            await _browser.Post($"/groups/{Group2}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = editorRole.Identifier
                });
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            var subjectId = _securableItem;

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{subjectId}.{editPatientPermission.Name}", permissions.Permissions);
            Assert.DoesNotContain($"app/{subjectId}.{viewPatientPermission.Name}", permissions.Permissions); // Denied by role
            Assert.Equal(2, permissions.Permissions.Count());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodName]
        public async Task TestUserBlacklist_SuccessAsync()
        {
            // Adding permissions
            var post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "viewpatient" + Guid.NewGuid()
                });
            });

            var viewPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "editpatient" + Guid.NewGuid()
                });
            });

            var editPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            // Adding roles
            var role = new RoleApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "viewer" + Guid.NewGuid(),
                Permissions = new List<PermissionApiModel> { viewPatientPermission }
            };

            post = await _browser.Post("/roles", with => // -3
            {
                with.HttpRequest();
                with.JsonBody(role);
            });

            var viewerRole = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -2
            {
                with.HttpRequest();
                role.Name = "editor" + Guid.NewGuid();
                role.Permissions = new List<PermissionApiModel> { editPatientPermission };
                with.JsonBody(role);
            });

            var editorRole = post.Body.DeserializeJson<RoleApiModel>();

            // Adding groups
            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group1,
                    GroupName = Group1,
                    GroupSource = Source1
                });
            });

            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group2,
                    GroupName = Group2,
                    GroupSource = Source2
                });
            });

            await _browser.Post($"/groups/{Group1}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = viewerRole.Identifier
                });
            });

            await _browser.Post($"/groups/{Group2}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = editorRole.Identifier
                });
            });

            // Adding blacklist (user cannot edit patient, even though role allows)
            var subjectId = _securableItem;

            editPatientPermission.PermissionAction = PermissionAction.Deny;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { editPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.DoesNotContain($"app/{_securableItem}.{editPatientPermission.Name}", permissions.Permissions);
            Assert.Contains($"app/{_securableItem}.{viewPatientPermission.Name}", permissions.Permissions);
            Assert.Equal(2, permissions.Permissions.Count());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodNameAttribute]
        public async Task TestUserWhitelist_SuccessAsync()
        {
            // Adding permissions
            var post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "viewpatient" + Guid.NewGuid()
                });
            });

            var viewPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            post = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = "editpatient" + Guid.NewGuid()
                });
            });

            var editPatientPermission = post.Body.DeserializeJson<PermissionApiModel>();

            // Adding roles
            var role = new RoleApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "viewer" + Guid.NewGuid(),
                Permissions = new List<PermissionApiModel> { viewPatientPermission }
            };

            post = await _browser.Post("/roles", with => // -3
            {
                with.HttpRequest();
                with.JsonBody(role);
            });

            var viewerRole = post.Body.DeserializeJson<RoleApiModel>();

            post = await _browser.Post("/roles", with => // -2
            {
                with.HttpRequest();
                role.Name = "editor" + Guid.NewGuid();
                role.Permissions = new List<PermissionApiModel> { editPatientPermission };
                with.JsonBody(role);
            });

            var editorRole = post.Body.DeserializeJson<RoleApiModel>();

            // Adding groups
            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group1,
                    GroupName = Group1,
                    GroupSource = Source1
                });
            });

            await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = Group2,
                    GroupName = Group2,
                    GroupSource = Source2
                });
            });

            await _browser.Post($"/groups/{Group1}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = viewerRole.Identifier
                });
            });

            await _browser.Post($"/groups/{Group2}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Id = editorRole.Identifier
                });
            });

            // Adding permission (user also can modify patient, even though role doesn't)
            var modifyPatientPermission = new PermissionApiModel
            {
                Grain = "app",
                SecurableItem = _securableItem,
                Name = "modifypatient" + Guid.NewGuid(),
                PermissionAction = PermissionAction.Allow
            };

            var response = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(modifyPatientPermission);
            });

            modifyPatientPermission.Id = response.Body.DeserializeJson<PermissionApiModel>().Id;

            var subjectId = _securableItem;

            await _browser.Post($"/user/{IdentityProvider}/{subjectId}/permissions", with =>
            {
                with.HttpRequest();
                var perms = new List<PermissionApiModel> { modifyPatientPermission };
                with.JsonBody(perms);
            });

            // Get the permissions
            var get = await _browser.Get("/user/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, get.StatusCode);
            var permissions = get.Body.DeserializeJson<UserPermissionsApiModel>();
            Assert.Contains($"app/{subjectId}.{editPatientPermission.Name}", permissions.Permissions);
            Assert.Contains($"app/{subjectId}.{viewPatientPermission.Name}", permissions.Permissions);
            Assert.Contains($"app/{subjectId}.{modifyPatientPermission.Name}", permissions.Permissions);
            Assert.Equal(4, permissions.Permissions.Count());
        }

        [Fact]
        [IntegrationTestsFixture.DisplayTestMethodNameAttribute]
        public async Task Test_GetGroups_UserNotFoundAsync()
        {
            var get = await _browser.Get("/user/foo/bar/groups", with =>
                {
                    with.HttpRequest();
                });

            Assert.Equal(HttpStatusCode.NotFound, get.StatusCode);
            Assert.Contains("User with SubjectId: bar and Identity Provider: foo was not found", get.Body.AsString());
        }

        [Fact]
        public async Task TestGetPermissions_FromCustomGroup_SuccessAsync()
        {
            var groupName = "group1" + Guid.NewGuid();

            var groupPostResponse = await _browser.Post("/groups", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    GroupName = groupName,
                    GroupSource = "Custom"
                });
            });

            Assert.Equal(HttpStatusCode.Created, groupPostResponse.StatusCode);
            var group = JsonConvert.DeserializeObject<GroupRoleApiModel>(groupPostResponse.Body.AsString());

            var userName = "user1" + Guid.NewGuid();
            var identityProvider = "TestIdp";

            var userGroupResponse = await _browser.Post($"/groups/{group.GroupName}/users", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    SubjectId = userName,
                    IdentityProvider = identityProvider
                });
            });

            Assert.Equal(HttpStatusCode.Created, userGroupResponse.StatusCode);

            var roleName = "role1" + Guid.NewGuid();
            var roleResponse = await _browser.Post("/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = roleName
                });
            });

            Assert.Equal(HttpStatusCode.Created, roleResponse.StatusCode);
            var role = JsonConvert.DeserializeObject<RoleApiModel>(roleResponse.Body.AsString());

            var permissionName = "permission1" + Guid.NewGuid();
            var permissionResponse = await _browser.Post("/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    Grain = "app",
                    SecurableItem = _securableItem,
                    Name = permissionName
                });
            });

            Assert.Equal(HttpStatusCode.Created, permissionResponse.StatusCode);
            var permission = JsonConvert.DeserializeObject<PermissionApiModel>(permissionResponse.Body.AsString());

            var groupRoleResponse = await _browser.Post($"/groups/{group.GroupName}/roles", with =>
            {
                with.HttpRequest();
                with.JsonBody(new
                {
                    role.Id
                });
            });

            Assert.Equal(HttpStatusCode.Created, groupRoleResponse.StatusCode);

            var permissionRoleResponse = await _browser.Post($"/roles/{role.Id}/permissions", with =>
            {
                with.HttpRequest();
                with.JsonBody(new[]
                {
                    new
                    {
                        permission.Id
                    }
                });
            });

            Assert.Equal(HttpStatusCode.Created, permissionRoleResponse.StatusCode);

            var permissionsResponse = await _browser.Get($"/user/{identityProvider}/{userName}/permissions", with =>
            {
                with.HttpRequest();
            });

            Assert.Equal(HttpStatusCode.OK, permissionsResponse.StatusCode);
            var permissions = JsonConvert.DeserializeObject<List<ResolvedPermissionApiModel>>(permissionsResponse.Body.AsString());
            Assert.Single(permissions);

            var resolvedPermission = permissions.First();
            Assert.Equal(permission.Id, resolvedPermission.Id);
            var resolvedRole = resolvedPermission.Roles.Single();
            Assert.Equal(role.Id, resolvedRole.Id);
        }
    }
}