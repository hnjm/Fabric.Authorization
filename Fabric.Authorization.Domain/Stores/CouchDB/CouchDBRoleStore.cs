﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Fabric.Authorization.Domain.Exceptions;
using Fabric.Authorization.Domain.Models;
using Fabric.Authorization.Domain.Services;
using Serilog;

namespace Fabric.Authorization.Domain.Stores.CouchDB
{
    public class CouchDbRoleStore : CouchDbGenericStore<Guid, Role>, IRoleStore
    {
        private readonly IPermissionStore _permissionStore;

        public CouchDbRoleStore(IDocumentDbService dbService, IPermissionStore permissionStore, ILogger logger, IEventContextResolverService eventContextResolverService) : base(dbService, logger, eventContextResolverService)
        {
            _permissionStore = permissionStore ?? throw new ArgumentNullException(nameof(permissionStore));
        }

        public override async Task<Role> Add(Role model)
        {
            model.Id = Guid.NewGuid();
            return await base.Add(model.Id.ToString(), model);
        }

        public override async Task Delete(Role model) => await base.Delete(model.Id.ToString(), model);

        public async Task<IEnumerable<Role>> GetRoles(string grain, string securableItem = null, string roleName = null)
        {
            var customParams = grain + securableItem + roleName;
            return roleName != null ?
                await DocumentDbService.GetDocuments<Role>("roles", "byname", customParams) :
                await DocumentDbService.GetDocuments<Role>("roles", "bysecitem", customParams);
        }

        public async Task<Role> AddPermissionsToRole(Role role, ICollection<Permission> permissions)
        {
            foreach (var permission in permissions)
            {
                role.Permissions.Add(permission);
            }

            await Update(role);
            return role;
        }

        public async Task<Role> RemovePermissionsFromRole(Role role, Guid[] permissionIds)
        {
            foreach (var permissionId in permissionIds)
            {
                if (role.Permissions.All(p => p.Id != permissionId))
                {
                    throw new NotFoundException<Permission>($"Permission with id {permissionId} not found on role {role.Id}");
                }
            }

            foreach (var permissionId in permissionIds)
            {
                var permission = role.Permissions.First(p => p.Id == permissionId);
                role.Permissions.Remove(permission);
            }

            await Update(role);
            return role;
        }

        public async Task RemovePermissionsFromRoles(Guid permissionId, string grain, string securableItem = null)
        {
            var roles = await GetRoles(grain, securableItem);

            // TODO: candidate for batch update
            foreach (var role in roles)
            {
                if (role.Permissions != null && role.Permissions.Any(p => p.Id == permissionId))
                {
                    var permission = role.Permissions.First(p => p.Id == permissionId);
                    role.Permissions.Remove(permission);
                    await Update(role);
                }
            }
        }

        public static CouchDbViews GetViews()
        {
            var views = new Dictionary<string, Dictionary<string, string>>
            {
                {
                    "byname", // Stores all roles by gain+secitem+name for easy retrieval.
                    new Dictionary<string, string>
                    {
                        { "map", "function(doc) { if (doc._id.indexOf('role:') !== -1) emit(doc.Grain+doc.SecurableItem+doc.Name, doc); }" },
                    }
                },
                {
                    "bysecitem", // Stores all roles by gain+secitem for easy retrieval.
                    new Dictionary<string, string>
                    {
                        { "map", "function(doc) { if (doc._id.indexOf('role:') !== -1) emit(doc.Grain+doc.SecurableItem, doc); }" },
                    }
                }
            };

            var couchViews = new CouchDbViews
            {
                id = "roles",
                views = views
            };

            return couchViews;
        }
    }
}