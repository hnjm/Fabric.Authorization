﻿using Catalyst.Fabric.Authorization.Models;
using Fabric.Authorization.API.Services;
using Fabric.Authorization.Domain.Exceptions;
using Fabric.Authorization.Domain.Models;
using Fabric.Authorization.Domain.Services;
using Fabric.Authorization.Domain.Validators;
using Nancy;
using Nancy.ModelBinding;
using Serilog;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Fabric.Authorization.API.Configuration;
using Fabric.Authorization.API.Constants;
using Fabric.Authorization.Domain;

namespace Fabric.Authorization.API.Modules
{
    public class EdwAdminModule : FabricModule<User>
    {
        private readonly UserService _userService;
        private readonly GroupService _groupService;
        private readonly IEDWAdminRoleSyncService _syncService;

        public EdwAdminModule(
            UserValidator validator,
            AccessService accessService,
            UserService userService,
            GroupService groupService,
            IEDWAdminRoleSyncService syncService,
            ILogger logger,
            IAppConfiguration appConfiguration = null) : base("/v1/edw/", logger, validator, accessService, appConfiguration)
        {
            _userService = userService ?? throw new ArgumentNullException(nameof(userService));
            _groupService = groupService ?? throw new ArgumentNullException(nameof(groupService));
            _syncService = syncService ?? throw new ArgumentNullException(nameof(syncService));

            Post("/roles",
                async param => await SyncUserIdentityRoles(param).ConfigureAwait(false), null,
                "SyncUserIdentityRoles");

            Post("/{groupName}/roles",
                async param => await SyncGroupIdentityRoles(param).ConfigureAwait(false), null,
                "SyncGroupIdentityRoles");
        }

        private async Task<dynamic> SyncUserIdentityRoles(dynamic param)
        {
            CheckInternalAccess();
            var resultList = new List<string>();
            var roleUserRequest = this.Bind<List<RoleUserRequest>>();

            foreach(var item in roleUserRequest)
            {
                if (item.IdentityProvider.Equals(IdentityConstants.ActiveDirectory, StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        User user = await _userService.GetUser(item.SubjectId, item.IdentityProvider);
                        await _syncService.RefreshDosAdminRolesAsync(user);
                    }
                    catch (NotFoundException<User>)
                    {
                        resultList.Add($"The user: {item.SubjectId} for identity provider: {item.IdentityProvider} was not found.");
                    }
                }
            }

            if (resultList.Any())
            {
                return CreateFailureResponse($"There were errors while processing the list: { String.Join("\n", resultList) }", HttpStatusCode.NotFound);
            }

            return HttpStatusCode.NoContent;
        }

        private async Task<dynamic> SyncGroupIdentityRoles(dynamic param)
        {
            CheckInternalAccess();

            var identityProvider = GetQueryParameter("identityProvider");
            var tenantId = GetQueryParameter("tenantId");
            GroupIdentifier groupIdentifier = CreateGroupIdentifier(SetIdentityProvider(identityProvider), tenantId, param.groupName.ToString());

            try
            {
                var group = await _groupService.GetGroup(groupIdentifier);
                foreach (var groupUser in group.Users)
                {
                    if (groupUser.IdentityProvider.Equals(IdentityConstants.ActiveDirectory, StringComparison.OrdinalIgnoreCase))
                    {
                        try
                        {
                            var user = await _userService.GetUser(groupUser.SubjectId, groupUser.IdentityProvider);
                            await _syncService.RefreshDosAdminRolesAsync(user);
                        }
                        catch (NotFoundException<User>)
                        {
                            return CreateFailureResponse(
                                $"The user: {groupUser.SubjectId} for identity provider: {groupUser.IdentityProvider} was not found.",
                                HttpStatusCode.NotFound);
                        }
                    }
                }

                return HttpStatusCode.NoContent;
            }
            catch (NotFoundException<Group>)
            {
                return CreateFailureResponse($"The group: {groupIdentifier} was not found",
                    HttpStatusCode.NotFound);
            }
        }
    }
}
