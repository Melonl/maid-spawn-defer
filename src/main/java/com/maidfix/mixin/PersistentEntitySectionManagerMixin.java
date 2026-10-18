package com.maidfix.mixin;

import net.minecraft.world.level.entity.EntitySection;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

import java.util.ArrayList;
import java.util.List;
import java.util.stream.Stream;

/**
 * 让「区段内实体遍历」基于快照，避免遍历期间增删实体导致 ConcurrentModificationException。
 * 目标：m_157543_(Visibility, EntitySection) 中对 EntitySection.m_156845_() 的 4 处调用。
 */
@Mixin(remap = false, targets = "net.minecraft.world.level.entity.PersistentEntitySectionManager")
public class PersistentEntitySectionManagerMixin {

    @Redirect(
        method = "m_157543_",
        require = 0,
        remap = false,
        at = @At(
            value = "INVOKE",
            remap = false,
            target = "Lnet/minecraft/world/level/entity/EntitySection;m_156845_()Ljava/util/stream/Stream;"
        )
    )
    @SuppressWarnings({"unchecked", "rawtypes"})
    private Stream<?> maidfix$snapshotSection(EntitySection section) {
        List<?> copy = new ArrayList<>(section.m_156845_().toList());
        return copy.stream();
    }
}
