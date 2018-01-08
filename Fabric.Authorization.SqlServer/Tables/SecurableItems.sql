CREATE TABLE [dbo].[SecurableItems](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[CreatedBy] [nvarchar](100) NOT NULL,
	[CreatedDateTimeUtc] [datetime] NOT NULL,
	[IsDeleted] [bit] NOT NULL,
	[ModifiedBy] [nvarchar](max) NULL,
	[ModifiedDateTimeUtc] [datetime2](7) NULL,
	[Name] [nvarchar](200) NOT NULL,
	[ParentId] [int] NULL,
	[SecurableItemId] [uniqueidentifier] NOT NULL,
 CONSTRAINT [PK_SecurableItems] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [HCFabricAuthorizationData1]
) ON [HCFabricAuthorizationData1] TEXTIMAGE_ON [HCFabricAuthorizationData1]
GO

CREATE NONCLUSTERED INDEX [IX_SecurableItems_ParentId] ON [dbo].[SecurableItems]
(
	[ParentId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [HCFabricAuthorizationIndex1]
GO

CREATE NONCLUSTERED INDEX [IX_SecurableItems_SecurableItemId] ON [dbo].[SecurableItems]
(
	[SecurableItemId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [HCFabricAuthorizationIndex1]
GO

ALTER TABLE [dbo].[SecurableItems] ADD  DEFAULT ((0)) FOR [IsDeleted]
GO

ALTER TABLE [dbo].[SecurableItems]  WITH CHECK ADD  CONSTRAINT [FK_SecurableItems_SecurableItems_ParentId] FOREIGN KEY([ParentId])
REFERENCES [dbo].[SecurableItems] ([Id])
GO

ALTER TABLE [dbo].[SecurableItems] CHECK CONSTRAINT [FK_SecurableItems_SecurableItems_ParentId]
GO
